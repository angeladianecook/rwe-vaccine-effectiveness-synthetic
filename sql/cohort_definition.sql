-- =============================================================================
-- cohort_definition.sql  —  build the eligible study cohort (one row / member)
-- -----------------------------------------------------------------------------
-- RWE rationale: every credible RWE study starts by turning a raw claims feed
-- into a well-defined cohort with a transparent, pre-specified set of
-- inclusion/exclusion rules anchored to an index (cohort-entry) date. The two
-- choices that most often decide whether an estimate is believable are (1) a
-- continuous-enrollment / baseline (look-back) window so covariates and prior
-- events are actually observable, and (2) a clean washout that removes
-- prevalent outcomes. We make both explicit here. Exposure is assigned
-- separately in exposure_index.sql so eligibility stays exposure-agnostic.
--
-- Design (HPV vaccine effectiveness):
--   Inclusion : female; adult (>= 18) at index; >= 365 days of CONTINUOUS
--               enrollment (gaps <= 45 days bridged) with index set at the end
--               of that baseline window; index within the study period.
--   Exclusion : prior CIN2+/cervical-cancer diagnosis on/before index (washout);
--               death on/before index.
--   Index     : cohort-entry date = first qualifying (baseline_start + 365d).
--
-- Output: TABLE cohort. Run after schema.sql / data load; read by R/01.
-- =============================================================================

CREATE OR REPLACE TABLE cohort AS
WITH params AS (
    SELECT DATE '2006-01-01' AS study_start,
           DATE '2023-12-31' AS study_end,
           365               AS baseline_days,   -- required continuous baseline
           45                AS gap_days,         -- allowable enrollment gap
           18                AS min_age           -- "enrolled adults"
),

-- --- Continuous enrollment via gaps-and-islands -------------------------------
-- Merge a member's coverage spans into continuous periods, bridging gaps no
-- larger than `gap_days`. A new period begins whenever a span starts more than
-- `gap_days` after the furthest coverage seen so far for that member.
ranked AS (
    SELECT
        member_id,
        enroll_start,
        enroll_end,
        MAX(enroll_end) OVER (
            PARTITION BY member_id ORDER BY enroll_start, enroll_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_end
    FROM enrollment
),
flagged AS (
    SELECT
        r.*,
        CASE
            WHEN prior_max_end IS NULL THEN 1
            WHEN enroll_start > prior_max_end + (SELECT gap_days FROM params) THEN 1
            ELSE 0
        END AS new_period
    FROM ranked r
),
grouped AS (
    SELECT
        *,
        SUM(new_period) OVER (
            PARTITION BY member_id ORDER BY enroll_start, enroll_end
            ROWS UNBOUNDED PRECEDING
        ) AS period_id
    FROM flagged
),
periods AS (
    SELECT
        member_id,
        period_id,
        MIN(enroll_start) AS cov_start,
        MAX(enroll_end)   AS cov_end
    FROM grouped
    GROUP BY member_id, period_id
),

-- --- Apply baseline length, age, sex, and study-window criteria ---------------
qualifying AS (
    SELECT
        p.member_id,
        p.cov_start,
        p.cov_end,
        p.cov_start + pr.baseline_days AS index_date,      -- end of baseline window
        d.birth_year,
        d.sex,
        d.region,
        EXTRACT(YEAR FROM p.cov_start + pr.baseline_days) - d.birth_year AS age_at_index,
        ROW_NUMBER() OVER (PARTITION BY p.member_id
                           ORDER BY p.cov_start) AS period_rank
    FROM periods p
    CROSS JOIN params pr
    JOIN member_demographics d USING (member_id)
    WHERE (p.cov_end - p.cov_start) >= pr.baseline_days                       -- continuous enrollment
      AND d.sex = 'F'                                                        -- cervical-outcome population
      AND EXTRACT(YEAR FROM p.cov_start + pr.baseline_days) - d.birth_year >= pr.min_age  -- adult at index
      AND (p.cov_start + pr.baseline_days) BETWEEN pr.study_start AND pr.study_end        -- index in study window
)

-- --- Keep the first qualifying period; enforce washout & alive-at-index -------
SELECT
    q.member_id,
    q.index_date,
    q.cov_start                AS baseline_start,
    q.index_date               AS baseline_end,
    q.cov_end                  AS enrollment_end,
    q.birth_year,
    q.age_at_index,
    q.sex,
    q.region,
    m.death_date,
    -- Administrative end of follow-up: earliest of coverage end, study end, death.
    LEAST(q.cov_end,
          (SELECT study_end FROM params),
          COALESCE(m.death_date, (SELECT study_end FROM params))) AS followup_end
FROM qualifying q
LEFT JOIN mortality m USING (member_id)
WHERE q.period_rank = 1
  -- Washout: no prevalent CIN2+/cervical cancer on or before index.
  AND NOT EXISTS (
        SELECT 1 FROM medical_claims mc
        WHERE mc.member_id = q.member_id
          AND mc.dx_code IN ('N87.1', 'D06.9', 'C53.9')
          AND mc.claim_date <= q.index_date
  )
  -- Must be alive at cohort entry.
  AND (m.death_date IS NULL OR m.death_date > q.index_date);
