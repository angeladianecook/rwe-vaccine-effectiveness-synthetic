#!/usr/bin/env Rscript
# =============================================================================
# 03_outcome_ascertainment.R
# -----------------------------------------------------------------------------
# Purpose : Ascertain the study outcome within each member's follow-up window
#           and assemble the analysis set (time, event, exposure, covariates)
#           for the survival analysis.
#
# Reads   : data/synthetic/rwe.duckdb :: cohort, followup, medical_claims
# Writes  : data/synthetic/rwe.duckdb :: analysis_set
#           results/outcome_summary.csv
#
# RWE rationale: the outcome is the first INCIDENT high-grade cervical lesion
# (CIN2+) or cervical cancer observed strictly AFTER index and within follow-up
# (prevalent disease was excluded at cohort entry). Follow-up time runs from
# index to the earliest of: the outcome, disenrollment, death, or study end —
# so death acts as a censoring/competing event. We also capture baseline
# cervical-screening intensity as a measured confounder: screening drives both
# vaccine uptake (health-seeking behavior) and outcome detection, so it must be
# adjusted for in the model (it is the observable proxy for that behavior).
#
# Note: the generic plan frames this as an acute outcome (e.g. COVID-19
# hospitalization/death); this synthetic study instantiates the HPV ->
# cervical-cancer-prevention outcome. The ascertainment pattern is identical.
# =============================================================================

RWE_DB      <- Sys.getenv("RWE_DB", file.path("data", "synthetic", "rwe.duckdb"))
RESULTS_DIR <- "results"

# ICD-10-CM outcome set: CIN2 (N87.1), CIN3 / carcinoma in situ (D06.9),
# malignant neoplasm of cervix (C53.9).
ANALYSIS_SET_SQL <- "
CREATE OR REPLACE TABLE analysis_set AS
SELECT * FROM (
  WITH ev AS (
    SELECT f.member_id, MIN(mc.claim_date) AS event_date
    FROM followup f
    JOIN medical_claims mc USING (member_id)
    WHERE mc.dx_code IN ('N87.1','D06.9','C53.9')
      AND mc.claim_date >  f.index_date
      AND mc.claim_date <= f.followup_end
    GROUP BY f.member_id),
  scr AS (   -- baseline cervical-screening intensity (confounder proxy)
    SELECT f.member_id, COUNT(*) AS baseline_screen_n
    FROM followup f
    JOIN medical_claims mc USING (member_id)
    WHERE mc.proc_code IN ('88175','87624')      -- Pap / HPV co-test
      AND mc.claim_date <= f.index_date
    GROUP BY f.member_id)
  SELECT
    f.member_id,
    f.index_date,
    f.exposure_status,
    f.exposure_onset_date,
    c.age_at_index,
    c.region,
    COALESCE(s.baseline_screen_n, 0) AS baseline_screen_n,
    (ev.event_date IS NOT NULL)::INTEGER AS event,
    LEAST(COALESCE(ev.event_date, f.followup_end), f.followup_end) AS exit_date,
    date_diff('day', f.index_date,
              LEAST(COALESCE(ev.event_date, f.followup_end), f.followup_end)) AS time_days
  FROM followup f
  JOIN cohort c USING (member_id)
  LEFT JOIN ev  USING (member_id)
  LEFT JOIN scr s USING (member_id)
)
WHERE time_days > 0    -- drop zero-length follow-up (no person-time at risk)
"

main <- function() {
  suppressPackageStartupMessages({ library(DBI); library(duckdb) })
  dir.create(RESULTS_DIR, showWarnings = FALSE, recursive = TRUE)
  con <- dbConnect(duckdb::duckdb(), RWE_DB)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, ANALYSIS_SET_SQL)

  smry <- DBI::dbGetQuery(con, "
    SELECT exposure_status,
           COUNT(*)              AS n_members,
           SUM(event)            AS n_events,
           ROUND(SUM(time_days) / 365.25, 1) AS person_years
    FROM analysis_set GROUP BY 1 ORDER BY 1")
  utils::write.csv(smry, file.path(RESULTS_DIR, "outcome_summary.csv"),
                   row.names = FALSE)

  cat("Outcome ascertainment (incident CIN2+/cervical cancer)\n")
  cat("------------------------------------------------------\n")
  print(smry, row.names = FALSE)
  cat(sprintf("\nAnalysis set: %d members, %d events, %.1f person-years\n",
              sum(smry$n_members), sum(smry$n_events), sum(smry$person_years)))
}

if (sys.nframe() == 0L) main()
