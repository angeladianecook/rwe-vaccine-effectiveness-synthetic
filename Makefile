# Makefile — one-command pipeline for the synthetic RWE HPV vaccine-effectiveness study.
#
# `make all` runs the full pipeline end to end:
#   generate -> SQL cohort/exposure -> outcome -> survival analysis -> QC ->
#   render dashboard -> tests.
# Each stage is also runnable on its own. Override the cohort size with
# `make data N_MEMBERS=2000` (handy for a quick run); RWE_SEED sets the seed.

RSCRIPT := Rscript
DB      := data/synthetic/rwe.duckdb

.PHONY: all data cohort exposure outcome analysis qc dashboard test clean help

all: data cohort exposure outcome analysis qc dashboard test ## Run the whole pipeline

data: ## Generate the synthetic claims universe (+ planted anomaly)
	$(RSCRIPT) R/00_generate_synthetic_data.R

cohort: data ## Build the cohort and log the attrition table
	$(RSCRIPT) R/01_build_cohort.R

exposure: cohort ## Index exposure and define follow-up windows
	$(RSCRIPT) R/02_exposure_indexing.R

outcome: exposure ## Ascertain outcomes; assemble the analysis set
	$(RSCRIPT) R/03_outcome_ascertainment.R

analysis: outcome ## Kaplan-Meier, incidence rates, Cox -> vaccine effectiveness
	$(RSCRIPT) R/04_survival_analysis.R

qc: outcome ## Cross-source reconciliation; detect/quantify the planted anomaly
	$(RSCRIPT) R/05_qc_checks.R

dashboard: analysis qc ## Render the Quarto summary dashboard
	quarto render dashboard/index.qmd

test: ## Run the testthat suite
	$(RSCRIPT) tests/testthat.R

clean: ## Remove generated data and outputs
	rm -f $(DB) $(DB).wal
	rm -rf data/synthetic/sample data/synthetic/ground_truth.rds
	rm -rf results
	rm -f dashboard/index.html
	rm -rf dashboard/index_files

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
