# PLAN.md — `rwe-vaccine-effectiveness-synthetic`

A flagship portfolio project that recreates a realistic **real-world evidence (RWE)
vaccine-effectiveness study** end-to-end on **fully synthetic** administrative
claims data. Built in **R + SQL (DuckDB)**, reproducible via **Docker** with a
single `make all`, tested with **testthat**, and verified in **CI**.

> **Why this exists.** My production RWE work is proprietary and cannot be shown.
> This repo demonstrates the same competencies — claims-schema SQL, cohort
> construction, exposure indexing, time-to-event analysis, and data quality
> control — on data I generate myself, so every line is inspectable and runnable.

This document is the build plan. It describes each component, the data model,
the analytic flow, and the order of implementation. **No analysis code has been
written yet** — the `R/` and `sql/` files are stubs with header contracts only.

---

## 1. Scientific framing (what the study answers)

**Question.** Among adults enrolled in a (synthetic) commercial/Medicare-style
claims plan, what is the effectiveness of a vaccine against a defined acute
outcome (e.g., hospitalization for the target infection), comparing vaccinated
vs. unvaccinated person-time?

**Design.** Observational new-user / exposure-indexed cohort with time-to-event
analysis. Vaccine effectiveness (VE) is reported as `VE = (1 − HR) × 100%`,
where HR is the adjusted hazard ratio from a Cox model (with a Kaplan–Meier and
incidence-rate companion analysis).

**Estimand (plain language).** The relative reduction in the hazard of the
outcome attributable to vaccination, over a defined follow-up window, in the
eligible source population, adjusting for measured confounders.

This is a *methods demonstration*, not a clinical claim. The "true" VE is a
parameter baked into the data generator, so the analysis can be validated
against ground truth.

---

## 2. Repository layout

```
rwe-vaccine-effectiveness-synthetic/
├── README.md                  # Front door: framing, quickstart, results teaser
├── PLAN.md                    # This file
├── LICENSE                    # MIT
├── Dockerfile                 # R + DuckDB + system deps, pinned
├── docker-compose.yml         # Brings up the analysis container (DuckDB is embedded)
├── Makefile                   # `make all` runs the full pipeline end to end
├── .gitignore
├── data/
│   └── synthetic/             # Generated parquet/duckdb; gitignored except a tiny sample
├── R/
│   ├── 00_generate_synthetic_data.R   # Build the synthetic claims universe (+ planted anomaly)
│   ├── 01_build_cohort.R              # Eligibility, enrollment windows, baseline covariates
│   ├── 02_exposure_indexing.R        # Index dates, exposed/unexposed person-time
│   ├── 03_outcome_ascertainment.R    # Outcome events, censoring, follow-up
│   ├── 04_survival_analysis.R        # KM, incidence rates, Cox; VE estimate
│   └── 05_qc_checks.R                # Cross-source reconciliation; catches the anomaly
├── sql/
│   ├── schema.sql            # DDL: enrollment, medical_claims, pharmacy_claims,
│   │                         #      vaccine_registry, mortality, provider
│   ├── cohort_definition.sql # Eligibility + continuous-enrollment logic
│   ├── exposure_index.sql    # Exposure index dates from claims + registry
│   └── feasibility_counts.sql# Attrition / feasibility counts (the "can we even do this" query)
├── dashboard/                # Quarto dashboard summarizing cohort + results
├── tests/
│   ├── testthat.R            # testthat entry point
│   └── testthat/             # Unit + data-contract tests
├── docs/
│   ├── protocol.md           # Mini study protocol / statistical analysis plan (SAP)
│   ├── data_dictionary.md    # Every table + column, types, allowed values
│   └── results_summary.md    # Plain-English findings, including the QC catch
└── .github/workflows/ci.yml  # Lint + build synthetic data + run tests on push
```

---

## 3. Data model (synthetic claims universe)

Modeled to *look and behave* like a HealthVerity/Optum-shaped claims extract,
stored as DuckDB tables / parquet. Sizes are configurable; defaults target a
cohort large enough to be interesting but small enough to run in CI.

| Table | Grain | Key columns | Purpose |
|---|---|---|---|
| `enrollment` | member × coverage span | `member_id`, `enroll_start`, `enroll_end`, `plan_type` | Continuous-enrollment denominator |
| `member_demographics` | member | `member_id`, `birth_year`, `sex`, `region` | Baseline covariates |
| `medical_claims` | claim line | `member_id`, `claim_date`, `dx_code`, `proc_code`, `place_of_service` | Outcomes, comorbidities, vaccine admin (CPT) |
| `pharmacy_claims` | fill | `member_id`, `fill_date`, `ndc`, `days_supply` | Comorbidity proxies; (optional) pharmacy-administered vaccines |
| `vaccine_registry` | dose | `member_id`, `dose_date`, `vaccine_code`, `dose_number`, `source` | Second exposure source for cross-reconciliation |
| `mortality` | member | `member_id`, `death_date`, `source` | Competing-risk / censoring |
| `provider` | provider | `provider_id`, `specialty`, `region` | Realism + provider-level checks |

**Ground-truth parameters** (hidden inside the generator, surfaced in tests):
- True vaccine effectiveness (target HR).
- Baseline outcome hazard, follow-up window.
- Confounding structure (e.g., age/comorbidity drive both uptake and outcome).
- Vaccine uptake rate and timing distribution.

---

## 4. The planted anomaly (the differentiator)

The generator deliberately injects a **systematic vaccine-classification error**
into one source feed: a defined subset of doses is miscoded so that the
**registry-derived** vaccination status disagrees with the **claims-derived**
status (e.g., a batch of CPT-coded administrations recorded under the wrong
vaccine code, or a date-shift in one feed).

- `05_qc_checks.R` detects it via **cross-source reconciliation** (registry vs.
  claims), **flags** the affected `member_id`s, **quantifies** the
  misclassification rate and its bias direction on the VE estimate, and writes a
  QC report artifact.
- `docs/results_summary.md` explains the catch in plain English and how it would
  be **escalated** (data-provider query, sensitivity analysis excluding affected
  records, quantitative bias analysis).
- A testthat test asserts that the QC step **actually finds** the planted records
  (count within tolerance), so the "catch" is reproducible, not a story.

This turns a real interview anecdote into something a reviewer can run and watch.

---

## 5. Analytic pipeline (execution order)

`make all` runs these in sequence; each step reads/writes DuckDB/parquet under
`data/synthetic/` and is individually re-runnable.

1. **`00_generate_synthetic_data.R`** — seedable generator. Builds all tables in
   §3, bakes in the ground-truth VE and confounding, and injects the §4 anomaly.
   Output: populated DuckDB database (+ tiny committed sample).
2. **`sql/schema.sql`** — creates the table DDL (invoked by step 1 / Makefile).
3. **`01_build_cohort.R` + `sql/cohort_definition.sql`** — apply eligibility:
   age, continuous enrollment (washout/baseline window), no prior outcome.
   Output: cohort table with baseline covariates.
4. **`02_exposure_indexing.R` + `sql/exposure_index.sql`** — assign index dates,
   define exposed vs. unexposed (or time-varying exposure) person-time. Handle
   immortal-time bias explicitly (documented design choice).
5. **`03_outcome_ascertainment.R`** — define outcome events from claims, apply
   censoring (disenrollment, death, end of study), compute follow-up time.
6. **`04_survival_analysis.R`** — Kaplan–Meier, crude incidence rates, adjusted
   Cox model; produce HR → VE with CIs; save figures + result tables.
7. **`05_qc_checks.R`** — data-contract checks + the cross-source anomaly catch;
   write QC report.
8. **`sql/feasibility_counts.sql`** — attrition table ("feasibility counts"),
   the query a study lead runs before committing to an analysis.
9. **`dashboard/`** — Quarto doc rendering cohort attrition, KM curve, VE
   estimate, and the QC finding into one shareable HTML page.

---

## 6. Reproducibility & engineering

- **Docker.** Single image: R (pinned via `rocker/r-ver` or similar) + DuckDB R
  package + Quarto + analysis deps. `docker-compose.yml` runs the pipeline in the
  container; DuckDB is embedded (no DB server needed).
- **Dependency pinning.** `renv` lockfile (or explicit pinned installs in the
  Dockerfile) so the environment is deterministic.
- **`make all`** targets (planned):
  `data` → `cohort` → `analysis` → `qc` → `dashboard` → `test`; plus `make clean`.
- **Determinism.** All randomness seeded; rerunning reproduces identical results.
- **Tests (testthat).** Data-contract tests (schema, keys, allowed values),
  pipeline-logic tests (cohort sizes, no negative follow-up), the anomaly-catch
  test, and a recovery test (estimated VE within tolerance of ground truth).
- **CI (`.github/workflows/ci.yml`).** On push/PR: install deps, generate a small
  synthetic dataset, run the pipeline on it, run testthat, (optionally) render the
  dashboard. Fail the build if any contract/recovery test fails.

---

## 7. Documentation

- **`docs/protocol.md`** — mini protocol/SAP: objective, design, population,
  exposure/outcome definitions, covariates, statistical methods, sensitivity
  analyses. Mirrors how a real RWE study is pre-specified.
- **`docs/data_dictionary.md`** — every table and column from §3 with types,
  allowed values, and provenance.
- **`docs/results_summary.md`** — plain-English findings: the VE estimate vs.
  ground truth, the KM/incidence story, and the QC catch + escalation narrative.
- **`README.md`** — the front door: the proprietary-work framing, a 60-second
  quickstart (`docker compose run … make all`), a results teaser, and a map of
  the repo.

---

## 8. Implementation order (proposed next steps, after you approve this plan)

1. Infra: finalize `Dockerfile`, `docker-compose.yml`, `Makefile`, `renv`.
2. `sql/schema.sql` + `00_generate_synthetic_data.R` (incl. ground truth + anomaly).
3. `docs/data_dictionary.md` (lock the contract before building on it).
4. `01`–`03` cohort/exposure/outcome + their SQL.
5. `04_survival_analysis.R` + result artifacts.
6. `05_qc_checks.R` + the anomaly-catch test.
7. testthat suite + `.github/workflows/ci.yml`.
8. `dashboard/` Quarto page.
9. `docs/protocol.md`, `docs/results_summary.md`, and the full `README.md`.

---

## 9. Open decisions (flag before coding)

- **Outcome & vaccine framing:** keep generic ("target infection / target
  vaccine") or theme it (e.g., influenza, COVID-19, RSV, herpes zoster)?
- **Exposure model:** simple new-user exposed/unexposed, or time-varying
  exposure with a landmark to handle immortal time? (Latter is more impressive,
  slightly more code.)
- **Dashboard tech:** Quarto (static, CI-friendly — recommended) vs. Shiny
  (interactive, needs a running process).
- **Cohort size defaults:** big enough to be realistic vs. fast enough for CI.
```
