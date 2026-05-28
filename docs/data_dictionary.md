# Data Dictionary

Every table and field in the synthetic claims universe produced by
`R/00_generate_synthetic_data.R` and written to `data/synthetic/rwe.duckdb`.
All data is **fully synthetic** and describes no real person. Defaults: 50,000
members (`N_MEMBERS`), seed `20260528` (`RWE_SEED`), study window 2006-01-01 to
2023-12-31. A 50-row preview of each table lives in `data/synthetic/sample/`.

This is the contract that `sql/schema.sql` and the data-contract tests enforce.

---

## `member_demographics` — one row per member
| Column | Type | Allowed values / notes |
|---|---|---|
| `member_id` | VARCHAR | Primary key. `M` + 7 digits (e.g. `M0000001`). |
| `birth_year` | INTEGER | 1985–2008 (cohorts passing through HPV-eligible ages in window). |
| `sex` | VARCHAR | `F`, `M` (~52% F). |
| `region` | VARCHAR | `Northeast`, `Midwest`, `South`, `West`. |

## `enrollment` — one row per coverage span (member × span)
| Column | Type | Allowed values / notes |
|---|---|---|
| `enroll_id` | VARCHAR | Primary key. `E` + 8 digits. |
| `member_id` | VARCHAR | FK → `member_demographics`. ~20% of members have two spans (a gap). |
| `enroll_start` | DATE | Coverage start (≥ 2006-01-01). |
| `enroll_end` | DATE | Coverage end (≤ 2023-12-31). |
| `plan_type` | VARCHAR | `Commercial`, `Medicaid`, `Medicare Advantage`. |

## `provider` — one row per provider (reference)
| Column | Type | Allowed values / notes |
|---|---|---|
| `provider_id` | VARCHAR | Primary key. `P` + 5 digits. |
| `specialty` | VARCHAR | `Family Medicine`, `Pediatrics`, `OB/GYN`, `Internal Medicine`, `Pharmacy`. |
| `region` | VARCHAR | Census region. |

## `medical_claims` — one row per claim line
| Column | Type | Allowed values / notes |
|---|---|---|
| `claim_id` | VARCHAR | Primary key. `MC` + 8 digits. |
| `member_id` | VARCHAR | FK → `member_demographics`. |
| `claim_date` | DATE | Service date, within a coverage span. |
| `dx_code` | VARCHAR | ICD-10-CM (see code legend below). |
| `proc_code` | VARCHAR | CPT/HCPCS (see code legend below). |
| `place_of_service` | VARCHAR | POS: `11` office, `22` outpatient hospital. |
| `provider_id` | VARCHAR | FK → `provider`. |

**Code legend (medical_claims).** The claims feed is the **claims-derived**
exposure/outcome signal used for cross-source reconciliation in QC:
- **HPV vaccine administration** — `dx_code = Z23`; `proc_code` = the TRUE
  product: `90649` Gardasil (HPV4), `90651` Gardasil 9 (HPV9), `90650`
  Cervarix (HPV2).
- **Cervical screening** — Pap: `dx_code = Z12.4`, `proc_code = 88175`;
  HPV co-test: `dx_code = Z11.51`, `proc_code = 87624`.
- **Outcome (incident CIN2+/cervical cancer)** — `proc_code = 57455`
  (colposcopy w/ biopsy); `dx_code` ∈ `N87.1` (CIN2), `D06.9` (CIN3 / carcinoma
  in situ), `C53.9` (malignant neoplasm of cervix).
- **Background encounters** — `dx_code` ∈ {`I10`, `E11.9`, `J06.9`, `M54.5`,
  `F41.1`, `Z00.00`, `K21.9`, `J45.909`}; `proc_code` ∈ {`99213`,`99214`,`99395`,`99396`}.

## `pharmacy_claims` — one row per fill
| Column | Type | Allowed values / notes |
|---|---|---|
| `pharmacy_claim_id` | VARCHAR | Primary key. `RX` + 8 digits. |
| `member_id` | VARCHAR | FK → `member_demographics`. |
| `fill_date` | DATE | Fill/administration date. |
| `ndc` | VARCHAR | NDC. HPV (pharmacy-administered): `00006-4045-41` Gardasil, `00006-4121-02` Gardasil 9, `58160-0830-11` Cervarix. Others are background fills. |
| `days_supply` | INTEGER | `0` for vaccines; `30`/`60`/`90` for background fills. |

## `vaccine_registry` — one row per dose (state IIS feed)
| Column | Type | Allowed values / notes |
|---|---|---|
| `registry_id` | VARCHAR | Primary key. `VR` + 8 digits. |
| `member_id` | VARCHAR | FK → `member_demographics`. |
| `dose_date` | DATE | Administration date. |
| `cvx_code` | INTEGER | `62` Gardasil (HPV4), `165` Gardasil 9 (HPV9), `118` Cervarix (HPV2). **See "Known data quality issues" — some CAIR2 values are intentionally wrong.** |
| `dose_number` | INTEGER | 1–3. |
| `source` | VARCHAR | IIS feed: `CAIR2`, `NYSIIS`, `TXIIS`, `WIR`, `FLSHOTS`, `other_IIS`. |

Registry captures ~95% of true doses (some real doses are missing, as in a real IIS).

## `mortality` — one row per deceased member
| Column | Type | Allowed values / notes |
|---|---|---|
| `member_id` | VARCHAR | FK → `member_demographics`. |
| `death_date` | DATE | Within the member's coverage envelope. Used for censoring / competing risk. |
| `source` | VARCHAR | `NDI`, `SSA_DMF`. |

## `product_availability` — one row per HPV product (reference)
| Column | Type | Allowed values / notes |
|---|---|---|
| `cvx_code` | INTEGER | Primary key. `62`, `165`, `118`. |
| `product_name` | VARCHAR | `Gardasil (HPV4)`, `Gardasil 9 (HPV9)`, `Cervarix (HPV2)`. |
| `available_from` | DATE | US availability start: `2006-06-08`, `2014-12-10`, `2009-10-16`. |
| `available_to` | DATE | US availability end: `2017-05-08`, `NULL` (ongoing), `2016-12-31`. |

This reference is what the QC plausibility check (`R/05_qc_checks.R`) tests
`(dose_date, cvx_code)` pairs against.

---

## Known data quality issues (intentional)

> ⚠️ **A systematic vaccine-classification anomaly is deliberately planted in the
> data** so a downstream QC step can catch it. It is injected in
> `R/00_generate_synthetic_data.R`; the **detection logic lives separately** in
> `R/05_qc_checks.R`.

**What is wrong.** Approximately **3% of `vaccine_registry` records** carry a
miscoded `cvx_code`. The error is **confined to a single feed — `source = "CAIR2"`**
(modeled on California's immunization registry) — and is **systematic**: affected
records have their `cvx_code` set to **165 (Gardasil 9)** even though their
`dose_date` is **before Gardasil 9's US availability (2014-12-10)**.

**Why it's detectable two independent ways:**
1. **Internal plausibility** — the `(dose_date, cvx_code)` pair violates
   `product_availability` (Gardasil 9 recorded before it existed). Plotting
   administrations over time by product makes the impossible doses visible.
2. **Cross-source reconciliation** — the affected members' **claims-derived**
   product (`medical_claims.proc_code` / `pharmacy_claims.ndc`) still reflects
   the TRUE early product (Gardasil/Cervarix), so registry and claims disagree.

**Ground truth.** The exact tampered `registry_id` set, the affected
`member_id` set, the injection rule, and the realized rate are saved to
`data/synthetic/ground_truth.rds` (key: `anomaly`). A testthat test compares the
QC output against this set so the "catch" is reproducible, not anecdotal.

**Not an anomaly (by design):** all *non-CAIR2* records and all
*non-tampered* CAIR2 records have `(dose_date, cvx_code)` pairs that fall within
the correct availability window.
