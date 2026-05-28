#!/usr/bin/env Rscript
# =============================================================================
# 02_exposure_indexing.R
# -----------------------------------------------------------------------------
# Purpose : Run sql/exposure_index.sql to ascertain HPV exposure across sources,
#           then define each member's post-exposure FOLLOW-UP WINDOW for the
#           time-to-event analysis (time origin, exposure-onset, censoring).
#
# Reads   : data/synthetic/rwe.duckdb :: cohort
#           sql/exposure_index.sql
# Writes  : data/synthetic/rwe.duckdb :: exposure, followup
#
# -----------------------------------------------------------------------------
# Clinical rationale for the follow-up window (cited reasoning):
#
#  * Time origin (t0) is the cohort-entry index_date, NOT the vaccination date.
#    Exposure is handled as TIME-VARYING so person-time before vaccination is
#    counted as unexposed; classifying ever-vaccinated members as exposed from
#    t0 would induce immortal-time bias (Suissa AJE 2008;167:492).
#
#  * Exposure-onset lag. HPV vaccines elicit seroconversion ~1 month after a
#    dose, with anamnestic immune response and protection against incident
#    HPV infection developing shortly thereafter (WHO HPV position paper,
#    Wkly Epidemiol Rec 2017;92:241-268). We therefore start "protected"
#    person-time after a short onset lag (ONSET_LAG_DAYS, default 14d) rather
#    than on the dose date itself. Members vaccinated BEFORE cohort entry
#    (prevalent users) are treated as protected from t0.
#
#  * Outcome latency. The outcome (CIN2+/cervical cancer) arises only after
#    persistent oncogenic HPV infection progresses over years (Schiffman et al.,
#    Lancet 2007;370:890-907). The vaccine acts upstream by preventing the
#    incident infection, so effectiveness accrues over long follow-up; we follow
#    members to administrative censoring (disenrollment / death / study end)
#    rather than imposing a fixed short risk window.
#
#  * The same machinery applies to an acute exposure/outcome pair (e.g. a drug
#    dispensation -> a 14-28 day on-treatment risk window for an acute event);
#    only the onset lag and censoring rule would change.
# =============================================================================

RWE_DB         <- Sys.getenv("RWE_DB", file.path("data", "synthetic", "rwe.duckdb"))
ONSET_LAG_DAYS <- as.integer(Sys.getenv("RWE_ONSET_LAG_DAYS", "14"))

run_sql_file <- function(con, path) {
  DBI::dbExecute(con, paste(readLines(path, warn = FALSE), collapse = "\n"))
}

# SQL to materialize the per-member follow-up window from cohort + exposure.
followup_sql <- function(onset_lag_days) {
  sprintf("
CREATE OR REPLACE TABLE followup AS
SELECT
  c.member_id,
  c.index_date,                                   -- time origin (t0)
  c.followup_end,                                 -- administrative censoring
  e.exposure_status,
  e.exposure_start_date,
  e.exposure_timing,
  -- Time-varying exposure onset: prevalent users protected from t0; incident
  -- users protected after a %d-day onset lag (see header).
  CASE
    WHEN e.exposure_start_date IS NULL            THEN NULL
    WHEN e.exposure_start_date <= c.index_date    THEN c.index_date
    ELSE e.exposure_start_date + %d
  END AS exposure_onset_date
FROM cohort c
JOIN exposure e USING (member_id)", onset_lag_days, onset_lag_days)
}

main <- function() {
  suppressPackageStartupMessages({ library(DBI); library(duckdb) })
  con <- dbConnect(duckdb::duckdb(), RWE_DB)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  run_sql_file(con, file.path("sql", "exposure_index.sql"))   # -> exposure
  DBI::dbExecute(con, followup_sql(ONSET_LAG_DAYS))           # -> followup

  smry <- DBI::dbGetQuery(con, "
    SELECT exposure_status,
           COALESCE(exposure_timing, 'n/a') AS exposure_timing,
           COUNT(*) AS n
    FROM followup GROUP BY 1, 2 ORDER BY 1, 2")

  cat(sprintf("Exposure indexing (onset lag = %d days)\n", ONSET_LAG_DAYS))
  cat("---------------------------------------\n")
  print(smry, row.names = FALSE)
  cat(sprintf("\nFollow-up windows defined for %d cohort members\n",
              DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM followup")$n))
}

if (sys.nframe() == 0L) main()
