-- =============================================================================
-- feasibility_counts.sql  —  cross-source feasibility / completeness report
-- -----------------------------------------------------------------------------
-- RWE rationale: before committing to a study you run a "can we even do this?"
-- query — the feasibility count. It answers, at scale and in one pass: how many
-- patients exist, how completely each DATA SOURCE covers them, how well sources
-- AGREE on the exposure (cross-source ascertainment), whether the DEMOGRAPHICS
-- are covered well enough to support the planned analysis, and how the cohort
-- ATTRITES through the headline inclusion criteria. Crucially it runs on the
-- RAW source tables (it does not depend on cohort_definition / exposure_index),
-- because feasibility is assessed first. The continuous-enrollment figure here
-- is an approximate total-covered-days proxy; cohort_definition.sql applies the
-- exact gaps-and-islands logic.
--
-- The cross-source block is where a registry-vs-claims discordance first shows
-- up as a count — the same signal the QC step later resolves to the planted
-- anomaly.
--
-- Output: VIEW feasibility_counts (seq, section, metric, n_members, pct_of_total).
-- =============================================================================

CREATE OR REPLACE VIEW feasibility_counts AS
WITH
total AS (SELECT COUNT(*) AS n FROM member_demographics),

-- HPV exposure evidence per member, by source family --------------------------
hpv_evidence AS (
    SELECT member_id, 'registry' AS src FROM vaccine_registry
    UNION ALL
    SELECT member_id, 'claims' FROM medical_claims
    WHERE proc_code IN ('90649', '90651', '90650')
    UNION ALL
    SELECT member_id, 'pharmacy' FROM pharmacy_claims
    WHERE ndc IN ('00006-4045-41', '00006-4121-02', '58160-0830-11')
),
src_flags AS (
    SELECT
        member_id,
        BOOL_OR(src = 'registry')                AS in_registry,
        BOOL_OR(src IN ('claims', 'pharmacy'))   AS in_claims   -- "claims-derived" administrative signal
    FROM hpv_evidence
    GROUP BY member_id
),

-- Approximate eligibility flags for the attrition funnel ----------------------
covered AS (
    SELECT member_id, SUM(enroll_end - enroll_start) AS days_covered
    FROM enrollment GROUP BY member_id
),
member_flags AS (
    SELECT
        d.member_id,
        d.sex,
        (2023 - d.birth_year)                 AS attained_age,
        COALESCE(c.days_covered, 0)           AS days_covered,
        COALESCE(s.in_registry, FALSE)        AS in_registry,
        COALESCE(s.in_claims,   FALSE)        AS in_claims
    FROM member_demographics d
    LEFT JOIN covered   c USING (member_id)
    LEFT JOIN src_flags s USING (member_id)
),

counts AS (
    -- 1. Source population -----------------------------------------------------
    SELECT 1 AS seq, 'source_population' AS section, 'all_members' AS metric,
           COUNT(*) AS n_members FROM member_demographics

    -- 2. Data-source coverage --------------------------------------------------
    UNION ALL SELECT 2, 'data_source_coverage', 'with_medical_claim',
           COUNT(DISTINCT member_id) FROM medical_claims
    UNION ALL SELECT 3, 'data_source_coverage', 'with_pharmacy_claim',
           COUNT(DISTINCT member_id) FROM pharmacy_claims
    UNION ALL SELECT 4, 'data_source_coverage', 'with_registry_record',
           COUNT(DISTINCT member_id) FROM vaccine_registry
    UNION ALL SELECT 5, 'data_source_coverage', 'with_mortality_record',
           COUNT(DISTINCT member_id) FROM mortality

    -- 3. Cross-source vaccine ascertainment (registry vs claims-derived) -------
    UNION ALL SELECT 10, 'cross_source_vaccine', 'hpv_any_source',
           COUNT(*) FROM src_flags
    UNION ALL SELECT 11, 'cross_source_vaccine', 'hpv_registry_only',
           COUNT(*) FROM src_flags WHERE in_registry AND NOT in_claims
    UNION ALL SELECT 12, 'cross_source_vaccine', 'hpv_claims_only',
           COUNT(*) FROM src_flags WHERE in_claims AND NOT in_registry
    UNION ALL SELECT 13, 'cross_source_vaccine', 'hpv_both_sources',
           COUNT(*) FROM src_flags WHERE in_registry AND in_claims
    UNION ALL SELECT 14, 'cross_source_vaccine', 'hpv_no_evidence',
           (SELECT n FROM total) - (SELECT COUNT(*) FROM src_flags)

    -- 4. Demographic coverage --------------------------------------------------
    UNION ALL SELECT 20, 'demographic_coverage', 'sex_female',
           COUNT(*) FROM member_demographics WHERE sex = 'F'
    UNION ALL SELECT 21, 'demographic_coverage', 'sex_male',
           COUNT(*) FROM member_demographics WHERE sex = 'M'
    UNION ALL SELECT 22, 'demographic_coverage', 'age_lt_18',
           COUNT(*) FROM member_flags WHERE attained_age < 18
    UNION ALL SELECT 23, 'demographic_coverage', 'age_18_26',
           COUNT(*) FROM member_flags WHERE attained_age BETWEEN 18 AND 26
    UNION ALL SELECT 24, 'demographic_coverage', 'age_27_45',
           COUNT(*) FROM member_flags WHERE attained_age BETWEEN 27 AND 45
    UNION ALL SELECT 25, 'demographic_coverage', 'age_46_plus',
           COUNT(*) FROM member_flags WHERE attained_age >= 46
    UNION ALL SELECT 26, 'demographic_coverage', 'region_northeast',
           COUNT(*) FROM member_demographics WHERE region = 'Northeast'
    UNION ALL SELECT 27, 'demographic_coverage', 'region_midwest',
           COUNT(*) FROM member_demographics WHERE region = 'Midwest'
    UNION ALL SELECT 28, 'demographic_coverage', 'region_south',
           COUNT(*) FROM member_demographics WHERE region = 'South'
    UNION ALL SELECT 29, 'demographic_coverage', 'region_west',
           COUNT(*) FROM member_demographics WHERE region = 'West'

    -- 5. Cohort attrition funnel (approximate; see header) ---------------------
    UNION ALL SELECT 30, 'cohort_attrition', 'step0_all_members',
           COUNT(*) FROM member_flags
    UNION ALL SELECT 31, 'cohort_attrition', 'step1_female',
           COUNT(*) FROM member_flags WHERE sex = 'F'
    UNION ALL SELECT 32, 'cohort_attrition', 'step2_female_adult',
           COUNT(*) FROM member_flags WHERE sex = 'F' AND attained_age >= 18
    UNION ALL SELECT 33, 'cohort_attrition', 'step3_continuous_enroll_365d',
           COUNT(*) FROM member_flags
           WHERE sex = 'F' AND attained_age >= 18 AND days_covered >= 365
    UNION ALL SELECT 34, 'cohort_attrition', 'step4_eligible_vaccinated',
           COUNT(*) FROM member_flags
           WHERE sex = 'F' AND attained_age >= 18 AND days_covered >= 365
             AND (in_registry OR in_claims)
    UNION ALL SELECT 35, 'cohort_attrition', 'step4_eligible_unvaccinated',
           COUNT(*) FROM member_flags
           WHERE sex = 'F' AND attained_age >= 18 AND days_covered >= 365
             AND NOT (in_registry OR in_claims)
)

SELECT
    seq,
    section,
    metric,
    n_members,
    ROUND(100.0 * n_members / (SELECT n FROM total), 1) AS pct_of_total
FROM counts
ORDER BY seq;
