# E-Commerce Operations, Cohort Retention & Statistical BI Analytics

An end-to-end data analytics and business intelligence pipeline built on the **Olist Brazilian E-Commerce dataset (~100k orders across 7 relational tables)**. This project combines embedded columnar SQL analytics (**DuckDB**), non-parametric statistical hypothesis testing (**Python / SciPy**), and an interactive **Streamlit + Plotly** dashboard to quantify how logistics delays, installment financing, and product categories impact customer satisfaction and retention.

🔗 **Live Interactive Dashboard:** `[Insert Streamlit Community Cloud URL after Day 6]`

---

## 1. Business Objectives & Key Questions

1. **Logistics & Customer Satisfaction:** At what delivery delay threshold do 1–5 star customer reviews collapse, and which regions drive late shipments?
2. **Payment & Installment Behavior:** How do multi-month credit card installments (`2x–5x`, `6x+`) versus upfront/boleto payments affect Average Order Value (AOV) and cancellation rates?
3. **Customer Cohort Retention:** What proportion of first-time buyers return over a 12-month lifecycle, and how do seasonal spikes (e.g., Black Friday) affect 3-month rolling revenue?

---

## 2. Architecture & Data Pipeline

```text
Raw Kaggle CSVs (7 Relational Tables)
        │
        ▼
[DuckDB OLAP Engine] ──► sql/01_create_schema.sql & sql/02_kpi_queries.sql
        │                 (Pre-aggregated CTEs to prevent 1:N join fan-out,
        │                  window functions: LAG, RANK, FIRST_VALUE, rolling frames)
        ▼
Compressed Parquet Layer (data/processed/*.parquet, ZSTD)
        │
        ├──► [Python / SciPy Notebook] (notebooks/01_eda_and_stats.ipynb)
        │      └─ Mann-Whitney U, Chi-Square + Cramér's V, 95% Confidence Intervals
        │
        └──► [Streamlit + Plotly App] (app/app.py)
               └─ Interactive KPIs, Cohort Heatmap, Delay & Payment Drill-Downs