# Data Dictionary

> **Scaffold.** Table inventory only. Column-level types, allowed values, and
> provenance to be completed before building on the schema (PLAN.md §7).
> This is the contract that `sql/schema.sql` and the data-contract tests enforce.

| Table | Grain | Key columns (planned) | Purpose |
|---|---|---|---|
| `enrollment` | member × coverage span | `member_id`, `enroll_start`, `enroll_end`, `plan_type` | Continuous-enrollment denominator |
| `member_demographics` | member | `member_id`, `birth_year`, `sex`, `region` | Baseline covariates |
| `medical_claims` | claim line | `member_id`, `claim_date`, `dx_code`, `proc_code`, `place_of_service` | Outcome (CIN2+/cervical cancer dx), cervical screening (cytology/HPV test), comorbidities, HPV vaccine admin (CPT) |
| `pharmacy_claims` | fill | `member_id`, `fill_date`, `ndc`, `days_supply` | Comorbidity proxies |
| `vaccine_registry` | dose | `member_id`, `dose_date`, `cvx_code`, `dose_number`, `source` | Registry exposure source (state-IIS-shaped, e.g. CA CAIR2) for cross-reconciliation |
| `mortality` | member | `member_id`, `death_date`, `source` | Competing risk / censoring |
| `provider` | provider | `provider_id`, `specialty`, `region` | Realism + provider-level checks |
| `product_availability` | product | `cvx_code`, `product_name`, `available_from`, `available_to` | HPV product availability windows; QC checks dose dates against this |

**HPV products (illustrative — confirm CVX/dates when building):** Gardasil
(CVX 62, ~2006), Gardasil 9 (CVX 165, ~2014), Cervarix (CVX 118, ~2009; US
withdrawal ~2016).

<!-- TODO: per-column type / allowed-values / nullable detail for each table. -->
