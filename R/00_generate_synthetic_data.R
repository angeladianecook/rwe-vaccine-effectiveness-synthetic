# =============================================================================
# 00_generate_synthetic_data.R
# -----------------------------------------------------------------------------
# Purpose : Build the fully synthetic claims universe and write it to DuckDB.
#           Bakes in the ground-truth vaccine effectiveness, the confounding
#           structure, and the PLANTED cross-source classification anomaly.
#
# Reads   : sql/schema.sql                  (table DDL)
#           env RWE_SEED                     (deterministic seed; see compose)
# Writes  : data/synthetic/rwe.duckdb        (enrollment, member_demographics,
#                                             medical_claims, pharmacy_claims,
#                                             vaccine_registry, mortality, provider)
#           data/synthetic/ground_truth.rds  (true VE, hazards, anomaly spec)
#
# Contract: - Output tables conform to docs/data_dictionary.md.
#           - Re-running with the same seed reproduces identical data.
#           - The anomaly (see PLAN.md §4) is injected here and ONLY here.
#
# Status  : SCAFFOLD — header contract only. Not yet implemented.
# =============================================================================

message("[stub] R/00_generate_synthetic_data.R — not yet implemented")
