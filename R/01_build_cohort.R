#!/usr/bin/env Rscript
# =============================================================================
# 01_build_cohort.R
# -----------------------------------------------------------------------------
# Purpose : Materialize the study cohort by running sql/cohort_definition.sql
#           against the DuckDB database, then log an ATTRITION TABLE that shows
#           how many members remain after each inclusion/exclusion criterion.
#
# Reads   : data/synthetic/rwe.duckdb (base tables)
#           sql/cohort_definition.sql
# Writes  : data/synthetic/rwe.duckdb :: cohort, attrition
#           results/attrition_table.csv
#
# RWE rationale: reviewers and regulators look at the attrition (CONSORT-style)
# table first — it shows the source population, the impact of each criterion,
# and the final analytic N at a glance, and it is the simplest guard against a
# cohort that has been silently over- or under-selected. The funnel below
# mirrors sql/cohort_definition.sql exactly (its final row equals the cohort N).
# =============================================================================

RWE_DB      <- Sys.getenv("RWE_DB", file.path("data", "synthetic", "rwe.duckdb"))
RESULTS_DIR <- "results"

run_sql_file <- function(con, path) {
  DBI::dbExecute(con, paste(readLines(path, warn = FALSE), collapse = "\n"))
}

# Per-member eligibility flags at the FIRST structural baseline period
# (mirrors the gaps-and-islands logic in sql/cohort_definition.sql).
ATTRITION_FLAGS_SQL <- "
WITH params AS (
  SELECT DATE '2006-01-01' study_start, DATE '2023-12-31' study_end,
         365 baseline_days, 45 gap_days, 18 min_age),
ranked AS (
  SELECT member_id, enroll_start, enroll_end,
         MAX(enroll_end) OVER (PARTITION BY member_id ORDER BY enroll_start, enroll_end
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_max_end
  FROM enrollment),
flagged AS (
  SELECT *, CASE WHEN prior_max_end IS NULL
                   OR enroll_start > prior_max_end + (SELECT gap_days FROM params)
                 THEN 1 ELSE 0 END AS new_period
  FROM ranked),
grouped AS (
  SELECT *, SUM(new_period) OVER (PARTITION BY member_id ORDER BY enroll_start, enroll_end
             ROWS UNBOUNDED PRECEDING) AS period_id
  FROM flagged),
periods AS (
  SELECT member_id, period_id, MIN(enroll_start) cov_start, MAX(enroll_end) cov_end
  FROM grouped GROUP BY member_id, period_id),
firstq AS (
  SELECT member_id, cov_start, cov_start + (SELECT baseline_days FROM params) AS index_date,
         ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY cov_start) rn
  FROM periods CROSS JOIN params
  WHERE (cov_end - cov_start) >= baseline_days
    AND (cov_start + baseline_days) BETWEEN study_start AND study_end),
fq AS (SELECT * FROM firstq WHERE rn = 1)
SELECT
  d.member_id,
  (d.sex = 'F') AS is_female,
  (fq.member_id IS NOT NULL) AS has_baseline,
  (fq.index_date IS NOT NULL
     AND EXTRACT(YEAR FROM fq.index_date) - d.birth_year >= (SELECT min_age FROM params)) AS is_adult,
  (fq.index_date IS NOT NULL AND NOT EXISTS (
     SELECT 1 FROM medical_claims mc WHERE mc.member_id = d.member_id
       AND mc.dx_code IN ('N87.1','D06.9','C53.9') AND mc.claim_date <= fq.index_date)) AS no_prior_outcome,
  (fq.index_date IS NOT NULL AND NOT EXISTS (
     SELECT 1 FROM mortality m WHERE m.member_id = d.member_id
       AND m.death_date <= fq.index_date)) AS alive_at_index
FROM member_demographics d
LEFT JOIN fq USING (member_id)
"

# Build the cumulative attrition table from the per-member flags. -------------
build_attrition <- function(flags) {
  f <- flags
  keep <- list(
    rep(TRUE, nrow(f)),
    f$is_female,
    f$is_female & f$has_baseline,
    f$is_female & f$has_baseline & f$is_adult,
    f$is_female & f$has_baseline & f$is_adult & f$no_prior_outcome,
    f$is_female & f$has_baseline & f$is_adult & f$no_prior_outcome & f$alive_at_index
  )
  n_remaining <- vapply(keep, sum, integer(1))
  data.frame(
    step = seq_along(keep),
    criterion = c(
      "Source population (all members)",
      "Female (cervical-outcome population)",
      "+ Continuous enrollment >= 365d, index in study window",
      "+ Adult (>= 18 years) at index",
      "+ No prior CIN2+/cervical cancer (washout)",
      "+ Alive at index (final cohort)"),
    n_remaining = n_remaining,
    n_excluded  = c(NA_integer_, -diff(n_remaining)),
    pct_of_source = round(100 * n_remaining / n_remaining[1], 1),
    stringsAsFactors = FALSE
  )
}

main <- function() {
  suppressPackageStartupMessages({ library(DBI); library(duckdb) })
  dir.create(RESULTS_DIR, showWarnings = FALSE, recursive = TRUE)
  con <- dbConnect(duckdb::duckdb(), RWE_DB)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  run_sql_file(con, file.path("sql", "cohort_definition.sql"))
  n_cohort <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM cohort")$n

  flags     <- DBI::dbGetQuery(con, ATTRITION_FLAGS_SQL)
  attrition <- build_attrition(flags)
  stopifnot(tail(attrition$n_remaining, 1) == n_cohort)  # funnel must equal cohort

  DBI::dbWriteTable(con, "attrition", attrition, overwrite = TRUE)
  utils::write.csv(attrition, file.path(RESULTS_DIR, "attrition_table.csv"),
                   row.names = FALSE)

  cat("Cohort attrition\n----------------\n")
  print(attrition, row.names = FALSE)
  cat(sprintf("\nFinal analytic cohort: %d members\n", n_cohort))
}

if (sys.nframe() == 0L) main()
