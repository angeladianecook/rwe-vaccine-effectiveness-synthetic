-- =============================================================================
-- schema.sql  —  canonical DuckDB DDL for the synthetic claims universe
-- -----------------------------------------------------------------------------
-- RWE rationale: in real-world-evidence work the schema *is* the contract. A
-- study is only as trustworthy as the grain, keys, and allowed values of its
-- source tables, so we pin them explicitly here (primary keys, referential
-- integrity, value/range CHECKs) rather than relying on whatever a loader
-- happens to infer. This file is the authoritative definition that
-- docs/data_dictionary.md describes in prose and that the data-contract tests
-- enforce at runtime.
--
-- Notes:
--   * DuckDB is embedded (no server). All dates are DATE; codes are VARCHAR
--     except cvx_code / dose_number / birth_year / days_supply (INTEGER).
--   * R/00_generate_synthetic_data.R materializes equivalent tables directly
--     via dbWriteTable(); CREATE TABLE IF NOT EXISTS keeps this DDL idempotent
--     so it can be applied to a fresh database without clobbering a loaded one.
-- =============================================================================

-- One row per member -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS member_demographics (
    member_id   VARCHAR PRIMARY KEY,
    birth_year  INTEGER NOT NULL CHECK (birth_year BETWEEN 1900 AND 2025),
    sex         VARCHAR NOT NULL CHECK (sex IN ('F', 'M')),
    region      VARCHAR NOT NULL CHECK (region IN ('Northeast', 'Midwest', 'South', 'West'))
);

-- One row per coverage span (a member may have >1 span, separated by gaps) ------
CREATE TABLE IF NOT EXISTS enrollment (
    enroll_id    VARCHAR PRIMARY KEY,
    member_id    VARCHAR NOT NULL REFERENCES member_demographics (member_id),
    enroll_start DATE    NOT NULL,
    enroll_end   DATE    NOT NULL,
    plan_type    VARCHAR NOT NULL CHECK (plan_type IN ('Commercial', 'Medicaid', 'Medicare Advantage')),
    CHECK (enroll_end >= enroll_start)
);

-- One row per provider (reference) ---------------------------------------------
CREATE TABLE IF NOT EXISTS provider (
    provider_id VARCHAR PRIMARY KEY,
    specialty   VARCHAR NOT NULL,
    region      VARCHAR NOT NULL
);

-- One row per medical claim line ------------------------------------------------
-- Carries the CLAIMS-derived exposure/outcome signals: HPV administration
-- (proc_code 90649/90651/90650), cervical screening (88175 / 87624), and the
-- incident outcome (dx N87.1 / D06.9 / C53.9).
CREATE TABLE IF NOT EXISTS medical_claims (
    claim_id         VARCHAR PRIMARY KEY,
    member_id        VARCHAR NOT NULL REFERENCES member_demographics (member_id),
    claim_date       DATE    NOT NULL,
    dx_code          VARCHAR,            -- ICD-10-CM
    proc_code        VARCHAR,            -- CPT / HCPCS
    place_of_service VARCHAR,            -- POS code (e.g. 11 office, 22 outpatient)
    provider_id      VARCHAR REFERENCES provider (provider_id)
);

-- One row per pharmacy fill -----------------------------------------------------
-- Background fills plus pharmacy-ADMINISTERED HPV doses (NDC), i.e. the
-- "dispensation" exposure source analogous to a drug/antiviral feed.
CREATE TABLE IF NOT EXISTS pharmacy_claims (
    pharmacy_claim_id VARCHAR PRIMARY KEY,
    member_id         VARCHAR NOT NULL REFERENCES member_demographics (member_id),
    fill_date         DATE    NOT NULL,
    ndc               VARCHAR NOT NULL,
    days_supply       INTEGER NOT NULL CHECK (days_supply >= 0)
);

-- One row per registry dose (state IIS feed) -----------------------------------
-- The REGISTRY-derived exposure source. cvx_code is the field corrupted by the
-- intentional anomaly (see docs/data_dictionary.md); QC reconciles it against
-- product_availability and the claims-derived product.
CREATE TABLE IF NOT EXISTS vaccine_registry (
    registry_id VARCHAR PRIMARY KEY,
    member_id   VARCHAR NOT NULL REFERENCES member_demographics (member_id),
    dose_date   DATE    NOT NULL,
    cvx_code    INTEGER NOT NULL,
    dose_number INTEGER NOT NULL CHECK (dose_number >= 1),
    source      VARCHAR NOT NULL    -- IIS feed: CAIR2, NYSIIS, TXIIS, WIR, FLSHOTS, other_IIS
);

-- One row per deceased member (competing risk / censoring) ----------------------
CREATE TABLE IF NOT EXISTS mortality (
    member_id  VARCHAR PRIMARY KEY REFERENCES member_demographics (member_id),
    death_date DATE    NOT NULL,
    source     VARCHAR NOT NULL CHECK (source IN ('NDI', 'SSA_DMF'))
);

-- One row per HPV product (reference for the QC plausibility check) -------------
CREATE TABLE IF NOT EXISTS product_availability (
    cvx_code       INTEGER PRIMARY KEY,
    product_name   VARCHAR NOT NULL,
    available_from DATE    NOT NULL,
    available_to   DATE                -- NULL = still available
);
