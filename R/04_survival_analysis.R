#!/usr/bin/env Rscript
# =============================================================================
# 04_survival_analysis.R
# -----------------------------------------------------------------------------
# Purpose : Exposure-indexed time-to-event analysis of the synthetic HPV cohort.
#           Produces a Kaplan-Meier figure, crude & adjusted incidence rates,
#           and a time-varying Cox model -> vaccine effectiveness, VE=(1-HR)*100.
#
# Reads   : data/synthetic/rwe.duckdb :: analysis_set
# Writes  : results/ve_estimates.csv, results/incidence_rates.csv,
#           results/km_curve.png, results/cox_model.rds
#
# *** METHODS DEMONSTRATION ONLY. ***  Every number here is computed on FULLY
# SYNTHETIC data whose "true" effect was set by the data generator. These are
# NOT real HPV vaccine-effectiveness estimates and must not be read as clinical
# evidence. The point is to show the analytic machinery end to end and to check
# that it recovers the planted ground truth.
#
# Design notes:
#  * Exposure is TIME-VARYING (counting-process Surv(start, stop, event)):
#    person-time before vaccine onset is unexposed, after onset is exposed.
#    This avoids the immortal-time bias that an ever/never-at-baseline
#    classification would introduce (Suissa AJE 2008;167:492).
#  * The adjusted Cox model controls for age, region, and baseline cervical-
#    screening intensity (the measured proxy for the health-seeking confounder
#    that drives both uptake and detection).
#  * The KM figure is a DESCRIPTIVE companion by ever-vaccinated status and is
#    subject to immortal-time caveats; the time-varying Cox is the primary
#    estimate.
# =============================================================================

suppressPackageStartupMessages({
  library(survival)
  library(ggplot2)
})

RWE_DB      <- Sys.getenv("RWE_DB", file.path("data", "synthetic", "rwe.duckdb"))
RESULTS_DIR <- "results"

# --- Build counting-process intervals for time-varying exposure --------------
make_intervals <- function(df) {
  df$index_date <- as.Date(df$index_date)
  onset <- as.integer(as.Date(df$exposure_onset_date) - df$index_date)  # NA = never exposed
  t  <- as.numeric(df$time_days)
  ev <- as.integer(df$event)
  cov <- df[, c("member_id", "age_at_index", "region", "baseline_screen_n")]

  never     <- is.na(onset) | onset >= t          # exposure never reached during follow-up
  from_start <- !never & onset <= 0               # prevalent users: exposed from t0
  split     <- !never & onset > 0 & onset < t      # incident users: unexposed then exposed

  mk <- function(mask, start, stop, event, exposed) {
    if (!any(mask)) return(NULL)
    data.frame(cov[mask, , drop = FALSE],
               start = start, stop = stop, event = event, exposed = exposed,
               row.names = NULL)
  }
  out <- rbind(
    mk(never,      0,            t[never],      ev[never],   0L),
    mk(from_start, 0,            t[from_start], ev[from_start], 1L),
    mk(split,      0,            onset[split],  0L,          0L),  # pre-exposure
    mk(split,      onset[split], t[split],      ev[split],   1L)   # post-exposure
  )
  stopifnot(all(out$stop > out$start))
  out
}

# --- Crude & adjusted Cox -> HR and VE ---------------------------------------
fit_models <- function(iv) {
  iv$region <- factor(iv$region)
  crude <- coxph(Surv(start, stop, event) ~ exposed, data = iv)
  adj   <- coxph(Surv(start, stop, event) ~ exposed + age_at_index + region +
                   baseline_screen_n, data = iv)
  est <- function(m, label) {
    hr <- unname(exp(coef(m)["exposed"]))
    ci <- unname(exp(confint(m)["exposed", ]))
    data.frame(
      model = label, n_events = m$nevent,
      hr = hr, hr_lci = ci[1], hr_uci = ci[2],
      ve_pct = 100 * (1 - hr), ve_lci = 100 * (1 - ci[2]), ve_uci = 100 * (1 - ci[1]),
      p_value = summary(m)$coefficients["exposed", "Pr(>|z|)"],
      stringsAsFactors = FALSE)
  }
  list(table = rbind(est(crude, "crude"), est(adj, "adjusted (age, region, screening)")),
       model_adj = adj)
}

# --- Incidence rates by (time-varying) exposure ------------------------------
compute_incidence <- function(iv) {
  agg <- aggregate(cbind(person_years = (stop - start) / 365.25, events = event) ~ exposed,
                   data = iv, FUN = sum)
  agg$group <- ifelse(agg$exposed == 1L, "exposed (vaccinated) PT", "unexposed PT")
  agg$rate_per_1000py <- 1000 * agg$events / agg$person_years
  agg[, c("group", "events", "person_years", "rate_per_1000py")]
}

# --- Descriptive KM data (cumulative incidence by ever-vaccinated) -----------
km_data <- function(df) {
  fit <- survfit(Surv(as.numeric(time_days) / 365.25, event) ~ exposure_status, data = df)
  strata <- rep(sub("exposure_status=", "", names(fit$strata)), fit$strata)
  data.frame(time_years = fit$time,
             cum_inc_pct = 100 * (1 - fit$surv),
             group = strata, stringsAsFactors = FALSE)
}

plot_km <- function(kmdf) {
  ggplot(kmdf, aes(time_years, cum_inc_pct, color = group)) +
    geom_step(linewidth = 0.8) +
    labs(title = "Cumulative incidence of CIN2+/cervical cancer",
         subtitle = "Descriptive, by ever-vaccinated status — SYNTHETIC DATA (methods demo)",
         x = "Years since index", y = "Cumulative incidence (%)", color = NULL) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "top",
          # Solid white background so the figure reads on light AND dark pages.
          plot.background = element_rect(fill = "white", colour = NA))
}

main <- function() {
  suppressPackageStartupMessages({ library(DBI); library(duckdb) })
  dir.create(RESULTS_DIR, showWarnings = FALSE, recursive = TRUE)
  con <- dbConnect(duckdb::duckdb(), RWE_DB, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  df <- DBI::dbReadTable(con, "analysis_set")

  iv  <- make_intervals(df)
  fit <- fit_models(iv)
  inc <- compute_incidence(iv)

  utils::write.csv(fit$table, file.path(RESULTS_DIR, "ve_estimates.csv"), row.names = FALSE)
  utils::write.csv(inc, file.path(RESULTS_DIR, "incidence_rates.csv"), row.names = FALSE)
  saveRDS(fit$model_adj, file.path(RESULTS_DIR, "cox_model.rds"))
  ggsave(file.path(RESULTS_DIR, "km_curve.png"), plot_km(km_data(df)),
         width = 7, height = 4.5, dpi = 150)

  cat("Survival analysis  *** SYNTHETIC DATA — METHODS DEMONSTRATION ONLY ***\n")
  cat("---------------------------------------------------------------------\n")
  cat("Incidence rates (per 1,000 person-years):\n")
  print(inc, row.names = FALSE, digits = 3)
  cat("\nVaccine effectiveness  VE = (1 - HR) * 100%:\n")
  print(fit$table, row.names = FALSE, digits = 3)
  cat("\nWrote ve_estimates.csv, incidence_rates.csv, km_curve.png, cox_model.rds\n")
}

if (sys.nframe() == 0L) main()
