-- =============================================================================
-- exposure_index.sql  —  ascertain exposure and set the index date per patient
-- -----------------------------------------------------------------------------
-- RWE rationale: exposure in claims data is rarely captured by a single feed.
-- A vaccination (or, in a drug study, an antiviral/therapeutic DISPENSATION)
-- typically shows up across multiple sources that must be combined and then
-- reconciled: here an immunization REGISTRY (CVX), a medical-claim
-- ADMINISTRATION (CPT), and a pharmacy DISPENSATION (NDC). We take exposure as
-- evidence from ANY source and set the first-dose date as the exposure index;
-- dose PRESENCE is robust to the planted product-misclassification anomaly,
-- which corrupts the registry CVX (the product) but not the fact of a dose.
--
-- Immortal-time handling: time zero is the cohort-entry `index_date`. A member
-- is unexposed person-time until `exposure_start_date` and exposed thereafter
-- (time-varying), so survival code must NOT classify exposure at baseline.
-- `exposure_timing` distinguishes prevalent (vaccinated before entry; exposed
-- from time zero) from incident (vaccinated during follow-up) users.
--
-- We also surface the registry-derived product (CVX) and the claims-derived
-- product (CPT) so QC can reconcile the two sources downstream.
--
-- Output: TABLE exposure (one row per cohort member). Run after
-- cohort_definition.sql; read by R/02.
-- =============================================================================

CREATE OR REPLACE TABLE exposure AS
WITH
-- --- Exposure evidence from each source (aligned columns) ---------------------
doses AS (
    SELECT member_id, dose_date AS exposure_date, 'registry' AS src,
           cvx_code AS cvx, CAST(NULL AS VARCHAR) AS cpt
    FROM vaccine_registry
    UNION ALL
    SELECT member_id, claim_date, 'claims',
           CAST(NULL AS INTEGER), proc_code
    FROM medical_claims
    WHERE proc_code IN ('90649', '90651', '90650')          -- HPV4 / HPV9 / HPV2
    UNION ALL
    SELECT member_id, fill_date, 'pharmacy',
           CAST(NULL AS INTEGER), CAST(NULL AS VARCHAR)
    FROM pharmacy_claims
    WHERE ndc IN ('00006-4045-41', '00006-4121-02', '58160-0830-11')  -- HPV NDCs
),

-- --- Collapse to one row per member ------------------------------------------
per_member AS (
    SELECT
        member_id,
        MIN(exposure_date)                                           AS first_dose_date,
        BOOL_OR(src = 'registry')                                    AS exposed_registry,
        BOOL_OR(src = 'claims')                                      AS exposed_claims,
        BOOL_OR(src = 'pharmacy')                                    AS exposed_pharmacy,
        COUNT(*) FILTER (WHERE src = 'registry')                     AS n_registry_doses,
        -- Earliest product per source, for cross-source reconciliation in QC:
        ARG_MIN(cvx, exposure_date) FILTER (WHERE src = 'registry')  AS registry_first_cvx,
        ARG_MIN(cpt, exposure_date) FILTER (WHERE src = 'claims')    AS claims_first_cpt
    FROM doses
    GROUP BY member_id
)

-- --- One row per cohort member, exposed or not -------------------------------
SELECT
    c.member_id,
    c.index_date,                                              -- time zero (cohort entry)
    CASE WHEN pm.first_dose_date IS NULL THEN 'unvaccinated'
         ELSE 'vaccinated' END                       AS exposure_status,
    pm.first_dose_date                               AS exposure_start_date,  -- exposure begins (time-varying)
    CASE
        WHEN pm.first_dose_date IS NULL                 THEN NULL
        WHEN pm.first_dose_date <= c.index_date         THEN 'prevalent'  -- exposed from time zero
        ELSE 'incident'                                                   -- exposed during follow-up
    END                                              AS exposure_timing,
    COALESCE(pm.exposed_registry, FALSE)             AS exposed_registry,
    COALESCE(pm.exposed_claims,   FALSE)             AS exposed_claims,
    COALESCE(pm.exposed_pharmacy, FALSE)             AS exposed_pharmacy,
    COALESCE(pm.n_registry_doses, 0)                 AS n_registry_doses,
    pm.registry_first_cvx,                                     -- registry-derived product
    pm.claims_first_cpt                                        -- claims-derived product
FROM cohort c
LEFT JOIN per_member pm USING (member_id);
