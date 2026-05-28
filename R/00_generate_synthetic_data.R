# =============================================================================
# 00_generate_synthetic_data.R
# -----------------------------------------------------------------------------
# Purpose : Build the fully synthetic HPV-vaccination claims universe and write
#           it to DuckDB. Bakes in the ground-truth HPV vaccine effectiveness,
#           the confounding structure (incl. cervical-screening intensity), and
#           the PLANTED registry availability-timeline anomaly.
#
# Reads   : env RWE_SEED       (deterministic seed; default 20260528)
#           env N_MEMBERS      (cohort size; default 50000)
# Writes  : data/synthetic/rwe.duckdb        (8 tables; see docs/data_dictionary.md)
#           data/synthetic/ground_truth.rds   (true VE, hazards, anomaly spec)
#           data/synthetic/sample/*.csv       (tiny committed previews)
#
# Contract: - Output tables conform to docs/data_dictionary.md.
#           - Re-running with the same seed reproduces identical data.
#           - The anomaly (PLAN.md §4) is injected here and ONLY here; the
#             DETECTION logic lives separately in R/05_qc_checks.R.
#
# -----------------------------------------------------------------------------
# >>> INTENTIONAL DATA-QUALITY ANOMALY (documented; do not "fix" here) <<<
#   A systematic vaccine-classification error is injected into ~3% of the
#   registry-derived dose records, confined to a single feed (source = "CAIR2",
#   modeled on California's IIS). For those records the `cvx_code` is reassigned
#   to 165 (Gardasil 9) even though the `dose_date` precedes Gardasil 9's US
#   availability (2014-12-10). Two things therefore go wrong, by design:
#     (1) the (dose_date, cvx_code) pair violates `product_availability`; and
#     (2) the registry-derived product disagrees with the claims-derived
#         product (medical_claims CPT / pharmacy NDC still carry the TRUE
#         product), so cross-source reconciliation will flag the same members.
#   Ground truth (the exact tampered registry_id / member_id set) is saved to
#   ground_truth.rds so tests can confirm the downstream QC step catches it.
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

# --- Configuration -----------------------------------------------------------
seed       <- as.integer(Sys.getenv("RWE_SEED", "20260528"))
n_members  <- as.integer(Sys.getenv("N_MEMBERS", "50000"))
study_start <- as.Date("2006-01-01")
study_end   <- as.Date("2023-12-31")

out_dir    <- file.path("data", "synthetic")
sample_dir <- file.path(out_dir, "sample")
db_path    <- file.path(out_dir, "rwe.duckdb")
dir.create(sample_dir, recursive = TRUE, showWarnings = FALSE)

set.seed(seed)

# Date-safe pmin/pmax (base pmin/pmax drop the Date class).
dmin <- function(...) as.Date(pmin(...), origin = "1970-01-01")
dmax <- function(...) as.Date(pmax(...), origin = "1970-01-01")

# --- Ground-truth parameters (hidden inside the generator) -------------------
true_hr  <- 0.45            # adjusted hazard ratio for vaccination -> VE = 55%
base_rate <- 0.006          # baseline annual hazard of CIN2+/cervical cancer
b_screen <- 0.45            # screening intensity -> more outcome detection
b_cohort <- -0.15           # birth-cohort effect on baseline hazard
anomaly_rate <- 0.03        # fraction of registry records to corrupt

# --- HPV product reference (CVX / CPT / NDC + real availability windows) -----
products <- data.frame(
  product_key   = c("HPV4", "HPV9", "HPV2"),
  product_name  = c("Gardasil (HPV4)", "Gardasil 9 (HPV9)", "Cervarix (HPV2)"),
  cvx_code      = c(62L, 165L, 118L),
  cpt_code      = c("90649", "90651", "90650"),
  ndc           = c("00006-4045-41", "00006-4121-02", "58160-0830-11"),
  available_from = as.Date(c("2006-06-08", "2014-12-10", "2009-10-16")),
  available_to   = as.Date(c("2017-05-08", NA, "2016-12-31")),
  stringsAsFactors = FALSE
)
cvx_of <- setNames(products$cvx_code, products$product_key)
cpt_of <- setNames(products$cpt_code, products$product_key)
ndc_of <- setNames(products$ndc, products$product_key)

# =============================================================================
# 1. Member demographics
# =============================================================================
member_id  <- sprintf("M%07d", seq_len(n_members))
sex        <- sample(c("F", "M"), n_members, replace = TRUE, prob = c(0.52, 0.48))
# Birth cohorts that pass through HPV-eligible ages during the study window.
birth_year <- sample(1985:2008, n_members, replace = TRUE)
region     <- sample(c("Northeast", "Midwest", "South", "West"),
                     n_members, replace = TRUE, prob = c(0.18, 0.21, 0.38, 0.23))

# Latent health-seeking / screening propensity: the key confounder. It raises
# BOTH the chance of getting vaccinated AND the chance an outcome is detected.
screen_z <- rnorm(n_members)

member_demographics <- data.frame(
  member_id = member_id, birth_year = birth_year, sex = sex, region = region,
  stringsAsFactors = FALSE
)

# =============================================================================
# 2. Enrollment (coverage envelope per member, then 1-2 spans for the table)
# =============================================================================
max_start_off <- as.integer(as.Date("2018-01-01") - study_start)
cov_start <- study_start + sample(0:max_start_off, n_members, replace = TRUE)
cov_dur   <- round(rgamma(n_members, shape = 2.2, scale = 365 * 1.8))
cov_end   <- dmin(cov_start + cov_dur, study_end)
plan_type <- sample(c("Commercial", "Medicaid", "Medicare Advantage"),
                    n_members, replace = TRUE, prob = c(0.60, 0.31, 0.09))

# ~20% of members have a coverage gap (two spans); the rest have one span.
two_span <- runif(n_members) < 0.20
# Single-span members:
enr_single <- data.frame(
  member_id  = member_id[!two_span],
  enroll_start = cov_start[!two_span],
  enroll_end   = cov_end[!two_span],
  plan_type    = plan_type[!two_span],
  stringsAsFactors = FALSE
)
# Two-span members: split [start,end] into two spans around a gap.
ts <- which(two_span)
gap_a <- cov_start[ts] + round(0.40 * (cov_end[ts] - cov_start[ts]))
gap_b <- cov_start[ts] + round(0.60 * (cov_end[ts] - cov_start[ts]))
enr_two <- data.frame(
  member_id  = c(member_id[ts], member_id[ts]),
  enroll_start = c(cov_start[ts], gap_b),
  enroll_end   = c(gap_a, cov_end[ts]),
  plan_type    = c(plan_type[ts], plan_type[ts]),
  stringsAsFactors = FALSE
)
enrollment <- rbind(enr_single, enr_two)
enrollment <- enrollment[order(enrollment$member_id, enrollment$enroll_start), ]
enrollment <- data.frame(
  enroll_id = sprintf("E%08d", seq_len(nrow(enrollment))),
  enrollment, row.names = NULL, stringsAsFactors = FALSE
)

# =============================================================================
# 3. Providers (small reference table; referenced by medical claims)
# =============================================================================
n_prov <- 800L
provider <- data.frame(
  provider_id = sprintf("P%05d", seq_len(n_prov)),
  specialty   = sample(c("Family Medicine", "Pediatrics", "OB/GYN",
                         "Internal Medicine", "Pharmacy"),
                       n_prov, replace = TRUE, prob = c(.30, .22, .20, .18, .10)),
  region      = sample(c("Northeast", "Midwest", "South", "West"),
                       n_prov, replace = TRUE),
  stringsAsFactors = FALSE
)

# =============================================================================
# 4. Mortality (competing risk / censoring); generated before outcomes
# =============================================================================
attained_age <- 2023 - birth_year
p_death <- plogis(-5.2 + 0.045 * (attained_age - 25))
died <- rbinom(n_members, 1, p_death) == 1
death_span <- as.integer(cov_end - cov_start)
death_date <- as.Date(rep(NA_real_, n_members), origin = "1970-01-01")
death_date[died] <- cov_start[died] +
  floor(runif(sum(died)) * pmax(death_span[died], 1))
mortality <- data.frame(
  member_id  = member_id[died],
  death_date = death_date[died],
  source     = sample(c("NDI", "SSA_DMF"), sum(died), replace = TRUE,
                      prob = c(0.7, 0.3)),
  stringsAsFactors = FALSE
)

# =============================================================================
# 5. Vaccination status, dates, and TRUE product (the exposure)
# =============================================================================
# Uptake rises for younger birth cohorts (program began 2006) and with the
# screening-propensity confounder -> a classic confounded exposure.
cohort_term <- (birth_year - 1995) / 10
logit_vax <- -0.40 + 1.10 * cohort_term + 0.50 * screen_z +
  0.15 * (region == "West") + 0.10 * (sex == "F")
vaccinated <- rbinom(n_members, 1, plogis(logit_vax)) == 1

# First-dose date: drawn within the eligible age window, clipped to availability.
elig_start <- dmax(as.Date(paste0(birth_year + 11L, "-01-01")),
                   as.Date("2006-06-08"))
elig_end   <- dmin(as.Date(paste0(birth_year + 26L, "-12-31")), study_end)
elig_ok    <- as.integer(elig_end - elig_start) > 30
vaccinated <- vaccinated & elig_ok
vax_date   <- as.Date(rep(NA_real_, n_members), origin = "1970-01-01")
vidx       <- which(vaccinated)
vax_span   <- as.integer(elig_end[vidx] - elig_start[vidx])
vax_date[vidx] <- elig_start[vidx] + floor(runif(length(vidx)) * vax_span)

# TRUE product is determined by the calendar of the first dose (always within
# that product's real availability window -- only the anomaly will violate it).
prod_key <- rep(NA_character_, n_members)
pk <- ifelse(vax_date[vidx] >= as.Date("2015-01-01"), "HPV9",
        ifelse(vax_date[vidx] >= as.Date("2009-10-16") &
                 runif(length(vidx)) < 0.15, "HPV2", "HPV4"))
prod_key[vidx] <- pk

# Dose schedule: 2 or 3 doses at 0 / (60) / 180 days.
n_doses <- rep(0L, n_members)
n_doses[vidx] <- sample(2:3, length(vidx), replace = TRUE, prob = c(0.45, 0.55))

# Expand to one row per dose (vectorized).
mi      <- rep(vidx, n_doses[vidx])              # member index per dose
nd_row  <- rep(n_doses[vidx], n_doses[vidx])     # this member's total doses
dose_no <- sequence(n_doses[vidx])               # 1..k within each member
offset  <- ifelse(dose_no == 1L, 0L,
            ifelse(dose_no == 2L, ifelse(nd_row == 3L, 60L, 180L), 180L))
doses <- data.frame(
  member_id   = member_id[mi],
  dose_number = dose_no,
  dose_date   = vax_date[mi] + offset,
  product_key = prod_key[mi],
  cvx_code    = unname(cvx_of[prod_key[mi]]),
  cpt_code    = unname(cpt_of[prod_key[mi]]),
  ndc         = unname(ndc_of[prod_key[mi]]),
  source_iis  = NA_character_,
  stringsAsFactors = FALSE
)
doses <- doses[doses$dose_date <= study_end, ]   # drop doses past study end

# =============================================================================
# 6. Outcome: time to incident CIN2+/cervical cancer (females at risk)
# =============================================================================
# Piecewise-constant hazard with a single breakpoint at the vaccination date,
# giving a proper proportional-hazards effect (rate x true_hr after vaccination).
sim_tte <- function(rate1, vax_t, log_hr) {
  n <- length(rate1); hr <- exp(log_hr)
  neglogu <- -log(runif(n))
  t <- numeric(n)
  unvax   <- !is.finite(vax_t)                       # never vaccinated
  protect <- is.finite(vax_t) & vax_t <= 0           # protected from t = 0
  switch  <- is.finite(vax_t) & vax_t > 0            # hazard switches at vax_t
  t[unvax]   <- neglogu[unvax]   / rate1[unvax]
  t[protect] <- neglogu[protect] / (rate1[protect] * hr)
  s <- which(switch)
  H_v <- rate1[s] * vax_t[s]                         # cum. hazard up to vax
  before <- neglogu[s] <= H_v
  ts <- numeric(length(s))
  ts[before]  <- neglogu[s][before] / rate1[s][before]
  rem <- neglogu[s][!before] - H_v[!before]
  ts[!before] <- vax_t[s][!before] + rem / (rate1[s][!before] * hr)
  t[s] <- ts
  t
}

age21_date    <- as.Date(paste0(birth_year + 21L, "-01-01"))
at_risk_start <- dmax(cov_start, age21_date)
censor_date   <- dmin(cov_end, study_end,
                      ifelse(is.na(death_date), study_end, death_date))
censor_date   <- as.Date(censor_date, origin = "1970-01-01")

at_risk <- sex == "F" & at_risk_start < censor_date
rate1   <- base_rate * exp(b_screen * screen_z + b_cohort * cohort_term)
vax_t   <- rep(Inf, n_members)
vax_t[vaccinated] <- as.numeric(vax_date[vaccinated] -
                                  at_risk_start[vaccinated]) / 365.25

t_event_yr <- rep(Inf, n_members)
ar <- which(at_risk)
t_event_yr[ar] <- sim_tte(rate1[ar], vax_t[ar], log(true_hr))
event_date <- at_risk_start + round(t_event_yr * 365.25)
has_outcome <- at_risk & is.finite(t_event_yr) & event_date <= censor_date

# Outcome severity mix: CIN2 (N87.1), CIN3/CIS (D06.9), cervical cancer (C53.9).
oidx <- which(has_outcome)
outcome_dx <- sample(c("N87.1", "D06.9", "C53.9"), length(oidx),
                     replace = TRUE, prob = c(0.70, 0.25, 0.05))

# =============================================================================
# 7. Medical claims (immunization, screening, outcomes, background encounters)
# =============================================================================
bg_dx_pool   <- c("I10", "E11.9", "J06.9", "M54.5", "F41.1", "Z00.00",
                  "K21.9", "J45.909")
bg_proc_pool <- c("99213", "99214", "99395", "99396")

# (a) Immunization admin claims -- one per dose; CPT carries the TRUE product.
mc_imm <- data.frame(
  member_id        = doses$member_id,
  claim_date       = doses$dose_date,
  dx_code          = "Z23",
  proc_code        = doses$cpt_code,
  place_of_service = "11",
  stringsAsFactors = FALSE
)

# (b) Cervical screening -- Pap (88175) +/- HPV co-test; frequency rises with
#     screening propensity. Eligible = females from age 21 to censoring.
elig_f   <- sex == "F" & age21_date < censor_date
elig_yrs <- pmax(0, as.numeric(censor_date - dmax(at_risk_start, age21_date)) / 365.25)
lambda_s <- ifelse(elig_f, elig_yrs / pmax(3 - 0.4 * screen_z, 1.2), 0)
n_screen <- rpois(n_members, lambda_s)
si       <- rep(seq_len(n_members), n_screen)
s_span   <- as.integer(censor_date[si] - at_risk_start[si])
s_date   <- at_risk_start[si] + floor(runif(length(si)) * pmax(s_span, 1))
mc_pap <- data.frame(
  member_id = member_id[si], claim_date = s_date, dx_code = "Z12.4",
  proc_code = "88175", place_of_service = "11", stringsAsFactors = FALSE
)
cotest <- runif(length(si)) < 0.30
mc_hpv <- data.frame(
  member_id = member_id[si][cotest], claim_date = s_date[cotest],
  dx_code = "Z11.51", proc_code = "87624", place_of_service = "11",
  stringsAsFactors = FALSE
)

# (c) Outcome claims -- diagnosis + colposcopy/biopsy.
mc_out <- data.frame(
  member_id = member_id[oidx], claim_date = event_date[oidx],
  dx_code = outcome_dx, proc_code = "57455", place_of_service = "22",
  stringsAsFactors = FALSE
)

# (d) Background encounters for realism.
n_bg  <- rpois(n_members, 2.5)
bi    <- rep(seq_len(n_members), n_bg)
bg_span <- as.integer(cov_end[bi] - cov_start[bi])
mc_bg <- data.frame(
  member_id = member_id[bi],
  claim_date = cov_start[bi] + floor(runif(length(bi)) * pmax(bg_span, 1)),
  dx_code = sample(bg_dx_pool, length(bi), replace = TRUE),
  proc_code = sample(bg_proc_pool, length(bi), replace = TRUE),
  place_of_service = "11", stringsAsFactors = FALSE
)

medical_claims <- rbind(mc_imm, mc_pap, mc_hpv, mc_out, mc_bg)
ord <- order(medical_claims$member_id, medical_claims$claim_date)
medical_claims <- medical_claims[ord, ]
medical_claims <- data.frame(
  claim_id    = sprintf("MC%08d", seq_len(nrow(medical_claims))),
  medical_claims,
  provider_id = sample(provider$provider_id, nrow(medical_claims), replace = TRUE),
  row.names = NULL, stringsAsFactors = FALSE
)

# =============================================================================
# 8. Pharmacy claims (pharmacy-administered HPV doses + background fills)
# =============================================================================
# ~20% of vaccinated members had at least some doses administered at a pharmacy;
# these carry the TRUE product NDC (a second claims-derived exposure signal).
pharm_member <- member_id %in% sample(member_id[vidx],
                                      round(0.20 * length(vidx)))
rx_hpv <- doses[doses$member_id %in% member_id[pharm_member], ]
rx_hpv <- data.frame(
  member_id = rx_hpv$member_id, fill_date = rx_hpv$dose_date,
  ndc = rx_hpv$ndc, days_supply = 0L, stringsAsFactors = FALSE
)

bg_ndc_pool <- c("00093-4155-78", "00185-0127-01", "00093-1048-01",
                 "00093-7194-01", "00781-1506-01", "50580-0506-02")
n_rx  <- rpois(n_members, 1.8)
ri    <- rep(seq_len(n_members), n_rx)
rx_span <- as.integer(cov_end[ri] - cov_start[ri])
rx_bg <- data.frame(
  member_id = member_id[ri],
  fill_date = cov_start[ri] + floor(runif(length(ri)) * pmax(rx_span, 1)),
  ndc = sample(bg_ndc_pool, length(ri), replace = TRUE),
  days_supply = sample(c(30L, 60L, 90L), length(ri), replace = TRUE),
  stringsAsFactors = FALSE
)

pharmacy_claims <- rbind(rx_hpv, rx_bg)
ord <- order(pharmacy_claims$member_id, pharmacy_claims$fill_date)
pharmacy_claims <- pharmacy_claims[ord, ]
pharmacy_claims <- data.frame(
  pharmacy_claim_id = sprintf("RX%08d", seq_len(nrow(pharmacy_claims))),
  pharmacy_claims, row.names = NULL, stringsAsFactors = FALSE
)

# =============================================================================
# 9. Vaccine registry (state-IIS feed) + INJECT THE ANOMALY
# =============================================================================
# Registry captures ~95% of true doses. Source feed is assigned per member.
src_levels <- c("CAIR2", "NYSIIS", "TXIIS", "WIR", "FLSHOTS", "other_IIS")
member_source <- sample(src_levels, n_members, replace = TRUE,
                        prob = c(.28, .14, .18, .10, .12, .18))
reg <- doses[runif(nrow(doses)) < 0.95, ]
reg <- data.frame(
  member_id   = reg$member_id,
  dose_date   = reg$dose_date,
  cvx_code    = reg$cvx_code,
  dose_number = reg$dose_number,
  source      = member_source[match(reg$member_id, member_id)],
  stringsAsFactors = FALSE
)
reg <- reg[order(reg$member_id, reg$dose_date), ]
reg <- data.frame(
  registry_id = sprintf("VR%08d", seq_len(nrow(reg))),
  reg, row.names = NULL, stringsAsFactors = FALSE
)

# --- Anomaly injection (see top-of-file documentation) -----------------------
# Confine the systematic error to the CAIR2 feed: take records whose TRUE early
# product (Gardasil/Cervarix) was administered before Gardasil 9 existed, and
# relabel them as Gardasil 9 (CVX 165) -- impossible on those dates.
gardasil9_from <- as.Date("2014-12-10")
candidates <- which(reg$source == "CAIR2" &
                      reg$dose_date < gardasil9_from &
                      reg$cvx_code %in% c(62L, 118L))
n_anom <- min(round(anomaly_rate * nrow(reg)), length(candidates))
anom_rows <- sort(sample(candidates, n_anom))
reg$cvx_code[anom_rows] <- 165L            # <-- the planted misclassification
anom_registry_ids <- reg$registry_id[anom_rows]
anom_member_ids   <- unique(reg$member_id[anom_rows])
vaccine_registry  <- reg

# =============================================================================
# 10. Product-availability reference (what the QC plausibility check uses)
# =============================================================================
product_availability <- data.frame(
  cvx_code = products$cvx_code, product_name = products$product_name,
  available_from = products$available_from, available_to = products$available_to,
  stringsAsFactors = FALSE
)

# =============================================================================
# 11. Persist: DuckDB + ground truth + tiny CSV samples
# =============================================================================
tables <- list(
  member_demographics  = member_demographics,
  enrollment           = enrollment,
  provider             = provider,
  medical_claims       = medical_claims,
  pharmacy_claims      = pharmacy_claims,
  vaccine_registry     = vaccine_registry,
  mortality            = mortality,
  product_availability = product_availability
)

if (file.exists(db_path)) file.remove(db_path)
con <- dbConnect(duckdb::duckdb(), dbdir = db_path)
for (nm in names(tables)) {
  dbWriteTable(con, nm, tables[[nm]], overwrite = TRUE)
  utils::write.csv(utils::head(tables[[nm]], 50),
                   file.path(sample_dir, paste0(nm, ".csv")), row.names = FALSE)
}
dbDisconnect(con, shutdown = TRUE)

ground_truth <- list(
  seed = seed, n_members = n_members,
  study_start = study_start, study_end = study_end,
  true_hr = true_hr, true_ve = 1 - true_hr,
  params = list(base_rate = base_rate, b_screen = b_screen, b_cohort = b_cohort),
  products = products,
  n_vaccinated = sum(vaccinated), n_outcomes = sum(has_outcome),
  anomaly = list(
    type = "registry_product_date_violation",
    description = paste(
      "~3% of CAIR2 registry records relabeled to CVX 165 (Gardasil 9) on",
      "dose_date < 2014-12-10: violates product_availability AND disagrees",
      "with the claims-derived product (medical_claims CPT / pharmacy NDC)."),
    rule = "source=='CAIR2' & dose_date < 2014-12-10 & true cvx in {62,118} -> cvx_code=165",
    affected_registry_ids = anom_registry_ids,
    affected_member_ids   = anom_member_ids,
    n_records = length(anom_registry_ids),
    rate = length(anom_registry_ids) / nrow(vaccine_registry)
  )
)
saveRDS(ground_truth, file.path(out_dir, "ground_truth.rds"))

# --- Console summary ---------------------------------------------------------
cat(sprintf("Synthetic RWE HPV data generated (seed=%d)\n", seed))
cat(sprintf("  members            : %d\n", n_members))
cat(sprintf("  enrollment spans   : %d\n", nrow(enrollment)))
cat(sprintf("  medical_claims     : %d\n", nrow(medical_claims)))
cat(sprintf("  pharmacy_claims    : %d\n", nrow(pharmacy_claims)))
cat(sprintf("  vaccine_registry   : %d\n", nrow(vaccine_registry)))
cat(sprintf("  mortality          : %d\n", nrow(mortality)))
cat(sprintf("  vaccinated         : %d (%.1f%%)\n",
            sum(vaccinated), 100 * mean(vaccinated)))
cat(sprintf("  outcomes (CIN2+)   : %d\n", sum(has_outcome)))
cat(sprintf("  PLANTED anomalies  : %d registry records (%.2f%%), %d members\n",
            length(anom_registry_ids),
            100 * length(anom_registry_ids) / nrow(vaccine_registry),
            length(anom_member_ids)))
cat(sprintf("  -> wrote %s\n", db_path))
