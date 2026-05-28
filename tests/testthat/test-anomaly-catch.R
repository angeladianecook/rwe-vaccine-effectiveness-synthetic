# The signature test: the QC step must INDEPENDENTLY rediscover the planted
# vaccine-classification anomaly (without using any ground-truth labels) and
# flag exactly the records that were corrupted by the generator.

test_that("QC cross-source reconciliation catches exactly the planted anomaly", {
  ds  <- test_dataset()
  con <- dbConnect(duckdb::duckdb(), ds$db, read_only = TRUE)
  registry     <- dbReadTable(con, "vaccine_registry")
  claims_hpv   <- dbGetQuery(con, "SELECT member_id, proc_code FROM medical_claims
                                    WHERE proc_code IN ('90649','90651','90650')")
  availability <- dbReadTable(con, "product_availability")
  dbDisconnect(con, shutdown = TRUE)

  recon <- reconcile(registry, claims_hpv, availability)
  s     <- qc_summary(recon)

  truth <- ds$gt$anomaly
  expect_gt(s$n_records_flagged, 0)                                  # something was caught
  expect_setequal(s$flagged$registry_id, truth$affected_registry_ids)  # exactly the planted records
  expect_setequal(unique(s$flagged$member_id), truth$affected_member_ids)
  expect_equal(s$n_records_flagged, truth$n_records)
})

test_that("the anomaly is confined to the CAIR2 feed and detected both ways", {
  ds  <- test_dataset()
  con <- dbConnect(duckdb::duckdb(), ds$db, read_only = TRUE)
  registry     <- dbReadTable(con, "vaccine_registry")
  claims_hpv   <- dbGetQuery(con, "SELECT member_id, proc_code FROM medical_claims
                                    WHERE proc_code IN ('90649','90651','90650')")
  availability <- dbReadTable(con, "product_availability")
  dbDisconnect(con, shutdown = TRUE)

  s <- qc_summary(reconcile(registry, claims_hpv, availability))
  expect_equal(sort(unique(as.character(s$flagged$source))), "CAIR2")
  # both detectors agree (availability + cross-source), and rate is ~3%
  expect_true(all(s$flagged$reason == "availability+cross-source"))
  expect_lt(abs(s$pct_records / 100 - ds$gt$anomaly$rate), 1e-9)
})
