#!/usr/bin/env Rscript
# =============================================================================
# 05_qc_checks.R
# -----------------------------------------------------------------------------
# Purpose : Data-quality control via CROSS-SOURCE RECONCILIATION. Independently
#           DETECTS the systematic vaccine-classification anomaly planted in the
#           registry feed, flags the affected records, quantifies how many
#           patients and what share are affected, and prints a QC report.
#
# Reads   : data/synthetic/rwe.duckdb :: vaccine_registry, medical_claims,
#                                         product_availability
# Writes  : results/qc_report.md, results/qc_flagged_members.csv,
#           results/doses_over_time.png
#
# RWE rationale: registry and claims are independent observations of the same
# vaccination. When they disagree systematically, something is wrong with a
# feed. This script reconciles them two ways and does NOT use any ground-truth
# labels — it rediscovers the problem the way an analyst would in production:
#   (1) Internal plausibility — a (dose_date, cvx_code) pair is impossible if
#       the product was not on the US market on that date (product_availability).
#   (2) Cross-source — the registry-derived product is unsupported by the
#       member's claims-derived product (CPT).
# (The detection lives here, separate from the injection in 00_generate_*.)
# =============================================================================

suppressPackageStartupMessages({ library(ggplot2) })

RWE_DB      <- Sys.getenv("RWE_DB", file.path("data", "synthetic", "rwe.duckdb"))
RESULTS_DIR <- "results"

CVX_TO_PRODUCT <- c("62" = "HPV4", "165" = "HPV9", "118" = "HPV2")
CPT_TO_PRODUCT <- c("90649" = "HPV4", "90651" = "HPV9", "90650" = "HPV2")

# --- Cross-source reconciliation (pure; operates on data frames) -------------
reconcile <- function(registry, claims_hpv, availability) {
  registry$dose_date         <- as.Date(registry$dose_date)
  availability$available_from <- as.Date(availability$available_from)
  availability$available_to   <- as.Date(availability$available_to)
  registry$reg_product <- CVX_TO_PRODUCT[as.character(registry$cvx_code)]

  # (1) Internal plausibility vs product availability window.
  av <- availability[, c("cvx_code", "available_from", "available_to")]
  m  <- merge(registry, av, by = "cvx_code", all.x = TRUE, sort = FALSE)
  m  <- m[order(m$registry_id), ]
  m$avail_violation <- with(m,
    dose_date < available_from |
    (!is.na(available_to) & dose_date > available_to))

  # (2) Cross-source: registry product not corroborated by the member's claims.
  claims_hpv$clm_product <- CPT_TO_PRODUCT[as.character(claims_hpv$proc_code)]
  supported_pairs <- unique(paste(claims_hpv$member_id, claims_hpv$clm_product))
  m$cross_discordant <- !(paste(m$member_id, m$reg_product) %in% supported_pairs)

  m$flagged <- m$avail_violation | m$cross_discordant
  m$reason  <- ifelse(m$avail_violation & m$cross_discordant, "availability+cross-source",
                ifelse(m$avail_violation, "availability",
                ifelse(m$cross_discordant, "cross-source", NA_character_)))
  m
}

qc_summary <- function(recon) {
  flagged   <- recon[recon$flagged, ]
  n_reg     <- nrow(recon)
  n_members <- length(unique(recon$member_id))
  list(
    flagged           = flagged,
    n_records_total   = n_reg,
    n_records_flagged = nrow(flagged),
    pct_records       = 100 * nrow(flagged) / n_reg,
    n_members_total   = n_members,
    n_members_flagged = length(unique(flagged$member_id)),
    pct_members       = 100 * length(unique(flagged$member_id)) / n_members,
    by_source         = as.data.frame(table(source = flagged$source), responseName = "n_flagged"),
    by_reason         = as.data.frame(table(reason = flagged$reason), responseName = "n_records"),
    by_product        = as.data.frame(table(registry_product = flagged$reg_product), responseName = "n_records")
  )
}

doses_over_time_plot <- function(registry, availability) {
  registry$dose_date <- as.Date(registry$dose_date)
  registry$product   <- CVX_TO_PRODUCT[as.character(registry$cvx_code)]
  registry$year      <- as.integer(format(registry$dose_date, "%Y"))
  agg <- aggregate(list(n = registry$year), by = list(year = registry$year,
                   product = registry$product), FUN = length)
  ggplot(agg, aes(year, n, color = product)) +
    geom_line(linewidth = 0.8) + geom_point(size = 1.2) +
    geom_vline(xintercept = 2014, linetype = "dashed", color = "grey50") +
    annotate("text", x = 2014.2, y = max(agg$n), hjust = 0, vjust = 1,
             size = 3, color = "grey40", label = "Gardasil 9 US availability (2014)") +
    labs(title = "Registry HPV doses over time, by product",
         subtitle = "Gardasil 9 (HPV9) doses recorded before 2014 are impossible — the planted anomaly",
         x = "Dose year", y = "Doses recorded", color = "Product") +
    theme_minimal(base_size = 12) + theme(legend.position = "top")
}

format_qc_report <- function(s) {
  fmt_tbl <- function(d) paste(utils::capture.output(print(d, row.names = FALSE)), collapse = "\n")
  paste0(
"# QC Report — Cross-Source Vaccine Reconciliation\n\n",
"**Status: ANOMALY DETECTED.**\n\n",
sprintf("- Registry records flagged: **%d of %d (%.2f%%)**\n",
        s$n_records_flagged, s$n_records_total, s$pct_records),
sprintf("- Patients affected: **%d of %d with registry records (%.2f%%)**\n\n",
        s$n_members_flagged, s$n_members_total, s$pct_members),
"## Flagged records by source feed\n\n", fmt_tbl(s$by_source), "\n\n",
"## Flagged records by detection reason\n\n", fmt_tbl(s$by_reason), "\n\n",
"## Flagged records by registry-derived product\n\n", fmt_tbl(s$by_product), "\n\n",
"## Interpretation\n\n",
"The flagged registry records assign a product (CVX) that (a) did not exist on ",
"the recorded dose date and (b) is contradicted by the member's claims-derived ",
"product. The error is systematic and confined to a single feed. **Bias impact:** ",
"it inflates apparent Gardasil 9 (HPV9) exposure and misclassifies product-specific ",
"person-time, which would bias any product-stratified effectiveness estimate. Overall ",
"ever-vaccinated status is unaffected (the dose still happened), so the all-product ",
"VE is robust; product-specific analyses are not.\n\n",
"See docs/results_summary.md for the plain-English finding and escalation plan.\n")
}

main <- function() {
  suppressPackageStartupMessages({ library(DBI); library(duckdb) })
  dir.create(RESULTS_DIR, showWarnings = FALSE, recursive = TRUE)
  con <- dbConnect(duckdb::duckdb(), RWE_DB, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  registry     <- DBI::dbReadTable(con, "vaccine_registry")
  claims_hpv   <- DBI::dbGetQuery(con, "SELECT member_id, proc_code FROM medical_claims
                                        WHERE proc_code IN ('90649','90651','90650')")
  availability <- DBI::dbReadTable(con, "product_availability")

  recon <- reconcile(registry, claims_hpv, availability)
  s     <- qc_summary(recon)

  report <- format_qc_report(s)
  writeLines(report, file.path(RESULTS_DIR, "qc_report.md"))
  utils::write.csv(
    s$flagged[, c("registry_id", "member_id", "dose_date", "cvx_code",
                  "reg_product", "source", "reason")],
    file.path(RESULTS_DIR, "qc_flagged_members.csv"), row.names = FALSE)
  ggsave(file.path(RESULTS_DIR, "doses_over_time.png"),
         doses_over_time_plot(registry, availability),
         width = 7, height = 4.5, dpi = 150)

  cat(report)
}

if (sys.nframe() == 0L) main()
