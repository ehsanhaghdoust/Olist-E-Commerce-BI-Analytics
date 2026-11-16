from pathlib import Path
import duckdb

file_path = Path("sql/01_create_schema.sql")

try:
    if not file_path.exists():
        con = duckdb.connect("data/olist.duckdb")
        con.execute(file_path.read_text())
        print("Loaded tables:", con.execute("SHOW TABLES").fetchall())
    else:
        print("Tables are already loaded!")
except:
    SystemExit(0)
