# data/synthetic/

Generated artifacts live here: the DuckDB database (`rwe.duckdb`), parquet
extracts, and `ground_truth.rds`. **These are produced by
`R/00_generate_synthetic_data.R` and are git-ignored** (see repo `.gitignore`)
— regenerate them deterministically with `make data`.

A small committed **sample** (a few rows per table) will live here so reviewers
can see the shape of the data without running the pipeline. All data is fully
synthetic and describes no real person.
