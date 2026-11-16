from pathlib import Path
import duckdb
import runpy

def init_load():
    runpy.run_path("src/ingest.py", run_name="__main__")

init_load()
file_path = Path("data/olist.duckdb")
con = duckdb.connect("data/olist.duckdb")
count = con.execute("SELECt COUNT(*) FROM ORDERS").fetchone()[0]
print(f"The number of rows in orders is {count}")