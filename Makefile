# Makefile — one-command pipeline for the synthetic RWE vaccine-effectiveness study.
#
# `make all` runs the full pipeline end to end. Each stage is also runnable on
# its own. NOTE: the R/SQL stages are scaffolded but not yet implemented; the
# recipes below define the intended execution contract (see PLAN.md).

RSCRIPT := Rscript
DB      := data/synthetic/rwe.duckdb

.PHONY: all data cohort exposure outcome analysis qc dashboard test clean help

all: data cohort exposure outcome analysis qc dashboard test ## Run the whole pipeline

data: ## Generate the synthetic claims universe (+ planted anomaly)
	$(RSCRIPT) R/00_generate_synthetic_data.R

cohort: data ## Apply eligibility / continuous-enrollment to build the cohort
	$(RSCRIPT) R/01_build_cohort.R

exposure: cohort ## Assign index dates and exposed/unexposed person-time
	$(RSCRIPT) R/02_exposure_indexing.R

outcome: exposure ## Ascertain outcome events and censoring
	$(RSCRIPT) R/03_outcome_ascertainment.R

analysis: outcome ## Kaplan-Meier, incidence rates, Cox -> vaccine effectiveness
	$(RSCRIPT) R/04_survival_analysis.R

qc: outcome ## Cross-source reconciliation; detect/quantify the planted anomaly
	$(RSCRIPT) R/05_qc_checks.R

dashboard: analysis qc ## Render the Quarto summary dashboard
	quarto render dashboard

test: ## Run the testthat suite
	$(RSCRIPT) tests/testthat.R

clean: ## Remove generated data and outputs
	rm -f $(DB) $(DB).wal
	rm -f data/synthetic/*.parquet
	rm -rf output results
	rm -f dashboard/*.html

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
