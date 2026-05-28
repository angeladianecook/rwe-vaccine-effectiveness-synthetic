# Shared test setup: locate the project, load pipeline functions, and provide a
# helper that generates a small synthetic dataset on demand (cached per session).

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

# Locate the project root (RWE_PROJECT_ROOT is set by tests/testthat.R; fall
# back to walking up from the working directory).
rwe_root <- function() {
  marker <- file.path("R", "00_generate_synthetic_data.R")
  r <- Sys.getenv("RWE_PROJECT_ROOT", "")
  if (nzchar(r) && file.exists(file.path(r, marker))) return(r)
  d <- normalizePath(getwd())
  for (i in seq_len(6)) {
    if (file.exists(file.path(d, marker))) return(d)
    d <- dirname(d)
  }
  stop("Could not locate the project root (R/00_generate_synthetic_data.R).")
}
ROOT <- rwe_root()

# Source pipeline functions. The scripts' guarded `main()` does NOT run on
# source (sys.nframe() > 0), so this just imports their functions:
#   R/01 -> run_sql_file(), ATTRITION_FLAGS_SQL, build_attrition()
#   R/05 -> reconcile(), qc_summary()
source(file.path(ROOT, "R", "01_build_cohort.R"))
source(file.path(ROOT, "R", "05_qc_checks.R"))

# The 8 tables the generator is responsible for producing.
GENERATED_TABLES <- c(
  "member_demographics", "enrollment", "provider", "medical_claims",
  "pharmacy_claims", "vaccine_registry", "mortality", "product_availability")

# Generate a small synthetic dataset into `dir` with a fixed seed/size by
# running R/00 as a subprocess (exercises the real generator).
generate_dataset <- function(dir, seed = 123L, n = 1500L) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  status <- system2(
    "Rscript", shQuote(file.path(ROOT, "R", "00_generate_synthetic_data.R")),
    env = c(sprintf("RWE_DATA_DIR=%s", dir),
            sprintf("RWE_SEED=%d", as.integer(seed)),
            sprintf("N_MEMBERS=%d", as.integer(n))),
    stdout = FALSE, stderr = FALSE)
  if (!identical(status, 0L)) stop("data generator failed (exit ", status, ")")
  list(dir = dir,
       db  = file.path(dir, "rwe.duckdb"),
       gt  = readRDS(file.path(dir, "ground_truth.rds")))
}

# Build the primary small dataset once and reuse it across test files.
.rwe_cache <- new.env(parent = emptyenv())
test_dataset <- function() {
  if (is.null(.rwe_cache$ds)) {
    .rwe_cache$ds <- generate_dataset(file.path(tempdir(), "rwe_main"), seed = 123L)
  }
  .rwe_cache$ds
}
