from pathlib import Path
import duckdb

Path("data/processed").mkdir(parents=True, exist_ok=True)
con = duckdb.connect("data/olist.duckdb")

# 1. Export unified order-level table (1 row per order, no fan-out duplication)
con.execute("""
    COPY (
        WITH order_totals AS (
            SELECT
                order_id,
                COUNT(*) AS item_count,
                SUM(price) AS items_price,
                SUM(freight_value) AS total_freight
            FROM order_items
            GROUP BY order_id
        ),
        primary_payment AS (
            SELECT
                order_id,
                FIRST(payment_type ORDER BY payment_value DESC) AS main_payment_type,
                MAX(payment_installments) AS max_installments,
                SUM(payment_value) AS total_payment_value
            FROM payments
            GROUP BY order_id
        ),
        order_review AS (
            SELECT
                order_id,
                AVG(review_score) AS review_score
            FROM reviews
            GROUP BY order_id
        ),
        primary_category AS (
            SELECT
                oi.order_id,
                FIRST(COALESCE(ct.product_category_name_english, 'uncategorized')) AS main_category
            FROM order_items oi
            LEFT JOIN products p ON oi.product_id = p.product_id
            LEFT JOIN category_translation ct ON p.product_category_name = ct.product_category_name
            GROUP BY oi.order_id
        )
        SELECT
            o.order_id,
            c.customer_unique_id,
            c.customer_state,
            o.order_status,
            o.order_purchase_timestamp,
            DATE_DIFF('day', o.order_estimated_delivery_date, o.order_delivered_customer_date) AS delivery_delay_days,
            pc.main_category,
            ot.item_count,
            ot.items_price,
            ot.total_freight,
            pp.main_payment_type,
            pp.max_installments,
            pp.total_payment_value,
            r.review_score
        FROM orders o
        JOIN customers c ON o.customer_id = c.customer_id
        LEFT JOIN order_totals ot ON o.order_id = ot.order_id
        LEFT JOIN primary_payment pp ON o.order_id = pp.order_id
        LEFT JOIN order_review r ON o.order_id = r.order_id
        LEFT JOIN primary_category pc ON o.order_id = pc.order_id
    ) TO 'data/processed/orders_analytical.parquet' (FORMAT parquet, COMPRESSION zstd);
""")

# 2. Export cohort retention matrix directly for the Streamlit heatmap
con.execute("""
    COPY (
        WITH customer_orders AS (
            SELECT
                c.customer_unique_id,
                DATE_TRUNC('month', o.order_purchase_timestamp)::DATE AS order_month
            FROM orders o
            JOIN customers c ON o.customer_id = c.customer_id
            WHERE o.order_status = 'delivered'
        ),
        first_purchase AS (
            SELECT customer_unique_id, MIN(order_month) AS cohort_month
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
                / FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY month_number),
                2
            ) AS retention_pct
        FROM cohort_activity
        WHERE cohort_month >= DATE '2017-01-01' AND month_number <= 12
        ORDER BY cohort_month, month_number
    ) TO 'data/processed/cohort_retention.parquet' (FORMAT parquet, COMPRESSION zstd);
""")

print("orders_analytical.parquet rows:",
      con.execute("SELECT COUNT(*) FROM 'data/processed/orders_analytical.parquet'").fetchone()[0])
print("cohort_retention.parquet rows:",
      con.execute("SELECT COUNT(*) FROM 'data/processed/cohort_retention.parquet'").fetchone()[0])