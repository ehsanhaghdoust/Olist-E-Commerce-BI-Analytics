-- ============================================================================
-- QUERY 1: LOGISTICS & DELIVERY DELAY IMPACT ON CUSTOMER REVIEW SCORES
-- ============================================================================
-- BUSINESS OBJECTIVE:
--   Quantify how shipping accuracy (actual vs. promised delivery date) impacts
--   customer satisfaction (1-5 star ratings) and negative review rates (1-2 stars).
--   Helps operations teams identify the exact delay threshold where customer
--   trust breaks down.
--
-- DATA GRAIN & JOINS:
--   - Grain: One row per delivered order that has a submitted customer review.
--   - Joins `orders` (o) -> `customers` (c) -> `reviews` (r) on primary/foreign keys.
--   - Filters strictly to `order_status = 'delivered'` and excludes NULL timestamps
--     so unfulfilled or in-transit orders do not skew delay calculations.
--
-- SQL TECHNIQUES & LOGIC:
--   1. CTE `order_delivery`: Computes `delay_days` using `DATE_DIFF('day', estimated, actual)`.
--      * Negative value = delivered early (e.g., -5 means 5 days ahead of schedule).
--      * Zero = delivered on the exact estimated date.
--      * Positive value = delivered late (e.g., +6 means 6 days overdue).
--   2. CTE `bucketed`: Discretizes continuous `delay_days` into 5 ordered operational
--      tiers via `CASE WHEN` (evaluated top-down). Numeric prefixes ('1.', '2.', ...)
--      guarantee chronological sorting in `ORDER BY` without needing a separate sort key.
--   3. Final Aggregation & Window Share:
--      * `SUM(COUNT(*)) OVER ()`: Window function over the entire result set (empty `OVER()`
--        clause) computes the grand total of orders across all buckets so we can divide
--        each bucket's count by the total in a single pass without a self-join.
--      * Conditional aggregation (`SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)`)
--        calculates the exact percentage of dissatisfied customers ("detractors").
-- ============================================================================
WITH order_delivery AS (
    SELECT
        o.order_id,
        c.customer_state, -- which state does the user live in
        DATE_DIFF('day', o.order_estimated_delivery_date, o.order_delivered_customer_date) AS delay_days,
        r.review_score
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    JOIN reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
),
bucketed AS (
    SELECT
        CASE
            WHEN delay_days <= -5 THEN '1. Early (5+ days)'
            WHEN delay_days <= 0  THEN '2. On-Time (0 to 4 days early)'
            WHEN delay_days <= 5  THEN '3. Slightly Late (1-5 days)'
            WHEN delay_days <= 14 THEN '4. Late (6-14 days)'
            ELSE '5. Severely Late (15+ days)'
        END AS delivery_status,
        review_score,
        delay_days
    FROM order_delivery
)
SELECT
    delivery_status,
    COUNT(*) AS order_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders,
    ROUND(AVG(review_score), 2) AS avg_review_score,
    ROUND(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*), 2) AS bad_review_pct
FROM bucketed
GROUP BY delivery_status
ORDER BY delivery_status;


-- ============================================================================
-- QUERY 2: MONTHLY REVENUE, ORDER VOLUME & ROLLING 3-MONTH GROWTH TRENDS
-- ============================================================================
-- BUSINESS OBJECTIVE:
--   Track top-line marketplace growth over time, measure Month-over-Month (MoM)
--   volatility, and smooth seasonal spikes (such as Black Friday) using a trailing
--   3-month moving average.
--
-- DATA GRAIN & JOINS:
--   - Grain: One row per calendar month (`order_month`).
--   - Joins `orders` (o) with `order_items` (oi) because revenue lives at the
--     line-item level (`price` + `freight_value`), whereas timestamps live at
--     the order header level.
--   - Excludes `'canceled'` and `'unavailable'` orders to reflect realized GMV
--     (Gross Merchandise Value).
--
-- SQL TECHNIQUES & LOGIC:
--   1. CTE `monthly_sales`: Truncates purchase timestamps to the first day of each
--      month (`DATE_TRUNC('month', ...)::DATE`) and aggregates distinct orders,
--      gross revenue, and mean line-item value.
--   2. `LAG(gross_revenue) OVER (ORDER BY order_month)`: Looks back 1 row in chronological
--      order to retrieve the prior month's revenue for MoM % growth.
--   3. `NULLIF(..., 0)`: Defensive guard preventing division-by-zero errors if a prior
--      month ever had 0 revenue (returns NULL cleanly for the very first month).
--   4. `AVG(gross_revenue) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`:
--      Defines an explicit sliding window frame covering the current row plus the 2
--      preceding rows (a 3-month trailing moving average) to reveal underlying trend
--      direction independent of single-month noise.
-- ============================================================================
WITH monthly_sales AS (
    SELECT
        DATE_TRUNC('month', o.order_purchase_timestamp)::DATE AS order_month,
        COUNT(DISTINCT o.order_id) AS total_orders,
        ROUND(SUM(oi.price + oi.freight_value), 2) AS gross_revenue,
        ROUND(AVG(oi.price + oi.freight_value), 2) AS avg_item_value
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY 1
)
SELECT
    order_month,
    total_orders,
    gross_revenue,
    avg_item_value,
    ROUND(
        100.0 * (gross_revenue - LAG(gross_revenue) OVER (ORDER BY order_month))
        / NULLIF(LAG(gross_revenue) OVER (ORDER BY order_month), 0),
        2
    ) AS mom_revenue_growth_pct,
    ROUND(
        AVG(gross_revenue) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
        2
    ) AS rolling_3m_avg_revenue
FROM monthly_sales
ORDER BY order_month;


-- ============================================================================
-- QUERY 3: PAYMENT METHOD & INSTALLMENT TIER PERFORMANCE ANALYSIS
-- ============================================================================
-- BUSINESS OBJECTIVE:
--   Evaluate how payment methods (credit card, boleto, voucher, debit card) and
--   installment financing plans influence Average Order Value (AOV), total GMV
--   contribution, and order cancellation risk.
--
-- DATA GRAIN & JOINS:
--   - Grain: One row per (`payment_type`, `installment_tier`) combination.
--   - Joins `payments` (p) with `orders` (o) to connect payment structures with
--     fulfillment outcomes (`order_status = 'canceled'`).
--   - Filters out `'not_defined'` placeholder records (only ~3 corrupt rows in Olist).
--
-- SQL TECHNIQUES & LOGIC:
--   1. `CASE WHEN` Segmentation: Groups `payment_installments` into three behavioral
--      tiers: upfront single payments (`1x`), short-term (`2x-5x`), and long-term
--      financing (`6x+`)—essential for understanding Brazilian credit-card buying habits.
--   2. `COUNT(DISTINCT p.order_id)`: Prevents double-counting orders when a single order
--      is split across multiple payment records (e.g., voucher + credit card).
--   3. Conditional Cancellation Rate: Computes the share of orders in each payment
--      segment that ended up canceled (e.g., unpaid boleto slips vs. instant card approvals).
--   4. `RANK() OVER (ORDER BY total_volume DESC)`: Ranks every payment/installment
--      segment by total financial volume generated across the marketplace.
-- ============================================================================
WITH payment_summary AS (
    SELECT
        p.payment_type,
        CASE
            WHEN p.payment_installments = 1 THEN '1x (Full Payment)'
            WHEN p.payment_installments BETWEEN 2 AND 5 THEN '2x-5x Installments'
            ELSE '6x+ Installments'
        END AS installment_tier,
        COUNT(DISTINCT p.order_id) AS order_count,
        ROUND(AVG(p.payment_value), 2) AS avg_payment_value,
        ROUND(SUM(p.payment_value), 2) AS total_volume,
        ROUND(
            100.0 * SUM(CASE WHEN o.order_status = 'canceled' THEN 1 ELSE 0 END) / COUNT(*),
            2
        ) AS cancel_rate_pct
    FROM payments p
    JOIN orders o ON p.order_id = o.order_id
    WHERE p.payment_type != 'not_defined'
    GROUP BY 1, 2
)
SELECT
    *,
    RANK() OVER (ORDER BY total_volume DESC) AS volume_rank
FROM payment_summary
ORDER BY volume_rank;


-- ============================================================================
-- QUERY 4: MONTHLY CUSTOMER COHORT RETENTION MATRIX (REPEAT PURCHASE ANALYSIS)
-- ============================================================================
-- BUSINESS OBJECTIVE:
--   Measure true customer retention over a 12-month lifecycle by grouping buyers
--   into monthly acquisition cohorts based on their very first purchase and tracking
--   what percentage return in subsequent months (Month 0, Month 1, ..., Month 12).
--
-- DATA GRAIN & CRITICAL DOMAIN NUANCE:
--   - Grain: One row per (`cohort_month`, `month_number` offset).
--   - CRITICAL OLIST SCHEMA DETAIL: In Olist, `customers.customer_id` is regenerated
--     for EVERY single order! Joining on `customer_id` alone would show 0% repeat
--     buyers. You MUST join `orders` -> `customers` and group by `customer_unique_id`
--     to track the actual human buyer across multiple orders.
--
-- SQL TECHNIQUES & LOGIC:
--   1. CTE `customer_orders`: Maps each delivered order to `customer_unique_id` and
--      truncates the timestamp to `order_month`.
--   2. CTE `first_purchase`: Finds each unique user's acquisition date (`MIN(order_month)`),
--      defining their `cohort_month`.
--   3. CTE `cohort_activity`: Joins activity back to `first_purchase` and calculates
--      `month_number = DATE_DIFF('month', cohort_month, order_month)` (0 = acquisition
--      month, 1 = first month after acquisition, etc.).
--   4. `FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY month_number)`:
--      Window function partitioned by `cohort_month` extracts the Month-0 cohort size
--      and attaches it to every subsequent row in that cohort, allowing exact
--      `retention_pct = active_customers / cohort_size` calculation without another join.
--   5. Filters (`>= '2017-01-01'` and `month_number <= 12`): Excludes sparse 2016 pilot
--      months so the resulting matrix is clean and ready for a Plotly heatmap.
-- ============================================================================
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        DATE_TRUNC('month', o.order_purchase_timestamp)::DATE AS order_month
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
),
first_purchase AS (
    SELECT
        customer_unique_id,
        MIN(order_month) AS cohort_month
    FROM customer_orders
    GROUP BY 1
),
cohort_activity AS (
    SELECT
        f.cohort_month,
        DATE_DIFF('month', f.cohort_month, co.order_month) AS month_number,
        COUNT(DISTINCT co.customer_unique_id) AS active_customers
    FROM first_purchase f
    JOIN customer_orders co ON f.customer_unique_id = co.customer_unique_id
    GROUP BY 1, 2
)
SELECT
    cohort_month,
    month_number,
    active_customers,
    FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY month_number) AS cohort_size,
    ROUND(
        100.0 * active_customers
        / FIRST_VALUE(active_customers) OVER