# The synthetic data generator must be deterministic: same seed -> identical
# data; different seed -> different data. Reproducibility is the foundation that
# makes every downstream result (and this whole repo) trustworthy.

test_that("generator output is identical for a fixed seed", {
  ds1 <- test_dataset()                                         # seed 123
  ds2 <- generate_dataset(file.path(tempdir(), "rwe_rep"), seed = 123L)

  con1 <- dbConnect(duckdb::duckdb(), ds1$db, read_only = TRUE)
  con2 <- dbConnect(duckdb::duckdb(), ds2$db, read_only = TRUE)
  on.exit({ dbDisconnect(con1, shutdown = TRUE); dbDisconnect(con2, shutdown = TRUE) }, add = TRUE)

  for (tb in GENERATED_TABLES) {
    d1 <- dbReadTable(con1, tb); d2 <- dbReadTable(con2, tb)
    d1 <- d1[do.call(order, d1), ]; rownames(d1) <- NULL
    d2 <- d2[do.call(order, d2), ]; rownames(d2) <- NULL
    expect_equal(d1, d2, info = tb)
  }
  # The planted anomaly is reproducible too.
  expect_equal(sort(ds1$gt$anomaly$affected_registry_ids),
               sort(ds2$gt$anomaly$affected_registry_ids))
})

test_that("a different seed yields different data", {
  ds1 <- test_dataset()
  ds3 <- generate_dataset(file.path(tempdir(), "rwe_seed999"), seed = 999L)

  con1 <- dbConnect(duckdb::duckdb(), ds1$db, read_only = TRUE)
  con3 <- dbConnect(duckdb::duckdb(), ds3$db, read_only = TRUE)
  on.exit({ dbDisconnect(con1, shutdown = TRUE); dbDisconnect(con3, shutdown = TRUE) }, add = TRUE)

  r1 <- dbReadTable(con1, "vaccine_registry")
  r3 <- dbReadTable(con3, "vaccine_registry")
  expect_false(isTRUE(all.equal(r1, r3)))
})
