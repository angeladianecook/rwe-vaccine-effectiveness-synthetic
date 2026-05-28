# =============================================================================
# 00_generate_synthetic_data.R
# -----------------------------------------------------------------------------
# Purpose : Build the fully synthetic HPV-vaccination claims universe and write
#           it to DuckDB. Bakes in the ground-truth HPV vaccine effectiveness,
#           the confounding structure (incl. cervical-screening intensity), and
#           the PLANTED registry availability-timeline anomaly.
#
# Reads   : sql/schema.sql                  (table DDL)
#           env RWE_SEED                     (deterministic seed; see compose)
# Writes  : data/synthetic/rwe.duckdb        (enrollment, member_demographics,
#                                             medical_claims, pharmacy_claims,
#                                             vaccine_registry, mortality,
#                                             provider, product_availability)
#           data/synthetic/ground_truth.rds  (true VE, hazards, anomaly spec)
#
# Contract: - Output tables conform to docs/data_dictionary.md.
#           - Re-running with the same seed reproduces identical data.
#           - The anomaly (PLAN.md §4) — registry (dose_date, cvx_code) pairs
#             that violate product availability and disagree with claims — is
#             injected here and ONLY here.
#
# Status  : SCAFFOLD — header contract only. Not yet implemented.
# =============================================================================

message("[stub] R/00_generate_synthetic_data.R — not yet implemented")
