# Study Protocol / Statistical Analysis Plan (SAP)

> **Scaffold.** Section headers and intent only. To be completed per PLAN.md §7.
> This mirrors how a real RWE study is pre-specified before any analysis is run.

## 1. Objective
_Effectiveness of a (synthetic) vaccine against a defined acute outcome._

## 2. Design
_Observational new-user / exposure-indexed cohort; time-to-event analysis._

## 3. Data source
_Synthetic HealthVerity/Optum-shaped claims (see docs/data_dictionary.md)._

## 4. Study population
_Eligibility: age, continuous enrollment (washout/baseline), no prior outcome._

## 5. Exposure definition
_Vaccine exposure from claims (CPT) + registry; index date; immortal-time handling._

## 6. Outcome definition
_Outcome event from claims; censoring (disenrollment, death, study end)._

## 7. Covariates / confounders
_Age, sex, region, comorbidity proxies driving both uptake and outcome._

## 8. Statistical methods
_KM, crude incidence rates, adjusted Cox; VE = (1 − HR) × 100% with CIs._

## 9. Sensitivity / QC analyses
_Cross-source reconciliation; analysis excluding anomaly-flagged records._
