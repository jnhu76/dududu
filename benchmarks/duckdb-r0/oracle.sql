-- DuckDB R0 SQL oracle over the TPC-H sf=1 lineitem.parquet dataset generated
-- by the official benchmark harness (parquet_projection_direct.benchmark).
--
-- Every statement is deterministic: exact DECIMAL/INTEGER arithmetic only (no
-- DOUBLE aggregates), and every multi-row result is fully ordered by a unique
-- key pair so row order cannot vary between runs.
--
-- Run with the CWD at build/duckdb-bench (so the relative dataset path and the
-- oracle-out/ target resolve the same way every time):
--   mkdir -p oracle-out/<run-id>
--   sed 's|oracle-out/|oracle-out/<run-id>/|g' <this file> > /tmp/oracle-run.sql
--   build/duckdb-native/<duckdb-sha>/duckdb < /tmp/oracle-run.sql
--   sha256sum oracle-out/<run-id>/*.csv
-- Two run-ids must produce identical SHA-256 per query (stable output hash).

COPY (
    SELECT COUNT(*) AS n_rows,
           SUM(l_quantity) AS sum_qty,
           SUM(l_extendedprice) AS sum_price,
           MIN(l_orderkey) AS min_orderkey,
           MAX(l_orderkey) AS max_orderkey
    FROM read_parquet('duckdb_benchmark_data/lineitem.parquet')
) TO 'oracle-out/q1.csv' (FORMAT CSV, HEADER FALSE, DELIMITER ',');

COPY (
    SELECT l_returnflag, l_linestatus,
           COUNT(*) AS cnt,
           SUM(l_quantity) AS sum_qty,
           SUM(l_extendedprice) AS sum_price,
           SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax)) AS sum_charge
    FROM read_parquet('duckdb_benchmark_data/lineitem.parquet')
    GROUP BY l_returnflag, l_linestatus
    ORDER BY l_returnflag, l_linestatus
) TO 'oracle-out/q2.csv' (FORMAT CSV, HEADER FALSE, DELIMITER ',');

COPY (
    SELECT l_orderkey, l_linenumber, l_partkey, l_extendedprice
    FROM read_parquet('duckdb_benchmark_data/lineitem.parquet')
    WHERE l_shipdate <= DATE '1998-09-02'
    ORDER BY l_orderkey, l_linenumber
    LIMIT 100000
) TO 'oracle-out/q3.csv' (FORMAT CSV, HEADER FALSE, DELIMITER ',');

COPY (
    SELECT COUNT(*) AS n_rows,
           MIN(length(l_comment)) AS min_comment_len,
           MAX(length(l_comment)) AS max_comment_len
    FROM read_parquet('duckdb_benchmark_data/lineitem.parquet')
) TO 'oracle-out/q4.csv' (FORMAT CSV, HEADER FALSE, DELIMITER ',');
