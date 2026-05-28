# Data Dictionary

> **Scaffold.** Table inventory only. Column-level types, allowed values, and
> provenance to be completed before building on the schema (PLAN.md §7).
> This is the contract that `sql/schema.sql` and the data-contract tests enforce.

| Table | Grain | Key columns (planned) | Purpose |
|---|---|---|---|
| `enrollment` | member × coverage span | `member_id`, `enroll_start`, `enroll_end`, `plan_type` | Continuous-enrollment denominator |
| `member_demographics` | member | `member_id`, `birth_year`, `sex`, `region` | Baseline covariates |
| `medical_claims` | claim line | `member_id`, `claim_date`, `dx_code`, `proc_code`, `place_of_service` | Outcomes, comorbidities, vaccine admin (CPT) |
| `pharmacy_claims` | fill | `member_id`, `fill_date`, `ndc`, `days_supply` | Comorbidity proxies |
| `vaccine_registry` | dose | `member_id`, `dose_date`, `vaccine_code`, `dose_number`, `source` | Second exposure source for cross-reconciliation |
| `mortality` | member | `member_id`, `death_date`, `source` | Competing risk / censoring |
| `provider` | provider | `provider_id`, `specialty`, `region` | Realism + provider-level checks |

<!-- TODO: per-column type / allowed-values / nullable detail for each table. -->
