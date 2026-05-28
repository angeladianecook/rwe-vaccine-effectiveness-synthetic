# =============================================================================
# 01_build_cohort.R
# -----------------------------------------------------------------------------
# Purpose : Apply study eligibility to the synthetic universe: age criteria,
#           continuous enrollment (washout / baseline window), and no prior
#           outcome. Attach baseline covariates.
#
# Reads   : data/synthetic/rwe.duckdb
#           sql/cohort_definition.sql        (eligibility + enrollment logic)
# Writes  : data/synthetic/rwe.duckdb :: cohort  (member_id, baseline covariates,
#                                                  eligibility window)
#
# Contract: - Every cohort member meets all inclusion/exclusion criteria in
#             docs/protocol.md.
#           - Eligibility windows are non-empty and within enrollment spans.
#
# Status  : SCAFFOLD — header contract only. Not yet implemented.
# =============================================================================

message("[stub] R/01_build_cohort.R — not yet implemented")
