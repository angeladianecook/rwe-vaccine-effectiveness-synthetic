# Study Protocol / Statistical Analysis Plan (SAP)

> **Scaffold.** Section headers and intent only. To be completed per PLAN.md §7.
> This mirrors how a real RWE study is pre-specified before any analysis is run.

## 1. Objective
_Effectiveness of HPV vaccination against incident high-grade cervical lesion
(CIN2+/CIN3) or cervical cancer, in a synthetic insured population._

## 2. Design
_Observational new-user / exposure-indexed cohort; time-to-event analysis.
Follow-up window defined explicitly (cancer-prevention latency)._

## 3. Data source
_Synthetic HealthVerity/Optum-shaped claims + a state-IIS-shaped vaccine
registry (modeled on CA CAIR2). See docs/data_dictionary.md._

## 4. Study population
_Eligibility: age band, continuous enrollment (washout/baseline), no prior
high-grade lesion / cervical cancer._

## 5. Exposure definition
_HPV vaccination from claims (CPT) + registry (CVX); index date; immortal-time
handling. Products: Gardasil (CVX 62), Gardasil 9 (CVX 165), Cervarix (CVX 118)._

## 6. Outcome definition
_Incident CIN2+/CIN3 or cervical cancer from claims; censoring (disenrollment,
death, study end)._

## 7. Covariates / confounders
_Age, region, comorbidity proxies, and cervical-screening intensity (cytology /
HPV testing) driving both uptake and detection._

## 8. Statistical methods
_KM, crude incidence rates, adjusted Cox; VE = (1 − HR) × 100% with CIs._

## 9. Sensitivity / QC analyses
_Product-availability plausibility + cross-source reconciliation; analysis
excluding anomaly-flagged records (PLAN.md §4)._
