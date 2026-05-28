# =============================================================================
# 02_exposure_indexing.R
# -----------------------------------------------------------------------------
# Purpose : Assign exposure index dates and define exposed vs. unexposed
#           person-time. Handles immortal-time bias explicitly (documented
#           design choice in docs/protocol.md).
#
# Reads   : data/synthetic/rwe.duckdb :: cohort, medical_claims, vaccine_registry
#           sql/exposure_index.sql           (index dates from claims + registry)
# Writes  : data/synthetic/rwe.duckdb :: exposure  (member_id, index_date,
#                                                    exposure status / start-stop)
#
# Contract: - Index dates fall within the eligibility window.
#           - Person-time accounting has no negative or overlapping intervals.
#
# Status  : SCAFFOLD — header contract only. Not yet implemented.
# =============================================================================

message("[stub] R/02_exposure_indexing.R — not yet implemented")
