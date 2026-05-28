# The cohort attrition funnel must be internally consistent (monotone, ending
# exactly at the materialized cohort), honor the inclusion criteria, and be
# stable across regenerations of the same seed.

test_that("attrition funnel is valid and equals the materialized cohort", {
  ds  <- test_dataset()
  con <- dbConnect(duckdb::duckdb(), ds$db)        # writable: cohort SQL creates a table
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  run_sql_file(con, file.path(ROOT, "sql", "cohort_definition.sql"))
  n_cohort <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM cohort")$n

  flags     <- dbGetQuery(con, ATTRITION_FLAGS_SQL)
  attrition <- build_attrition(flags)

  expect_equal(attrition$n_remaining[1], nrow(flags))             # source = all members
  expect_true(all(diff(attrition$n_remaining) <= 0))              # monotone non-increasing
  expect_equal(tail(attrition$n_remaining, 1), n_cohort)          # final = cohort
  expect_true(all(attrition$pct_of_source >= 0 &
                  attrition$pct_of_source <= 100))

  # Inclusion criteria actually hold in the cohort.
  expect_equal(dbGetQuery(con, "SELECT COUNT(*) AS n FROM cohort WHERE sex <> 'F'")$n, 0)
  expect_equal(dbGetQuery(con, "SELECT COUNT(*) AS n FROM cohort WHERE age_at_index < 18")$n, 0)
  expect_equal(dbGetQuery(con, "SELECT COUNT(*) AS n FROM cohort WHERE followup_end < index_date")$n, 0)
})

test_that("attrition numbers are stable across regenerations of the same seed", {
  ds  <- test_dataset()
  ds2 <- generate_dataset(file.path(tempdir(), "rwe_attr2"), seed = 123L)

  attr_of <- function(db) {
    con <- dbConnect(duckdb::duckdb(), db)
    on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
    run_sql_file(con, file.path(ROOT, "sql", "cohort_definition.sql"))
    build_attrition(dbGetQuery(con, ATTRITION_FLAGS_SQL))
  }
  expect_equal(attr_of(ds$db), attr_of(ds2$db))
})
