# testthat entry point — runs the suite under tests/testthat/.
# Invoked by `make test` and by CI (.github/workflows/ci.yml).
# Run from the project root (the Makefile does this).

library(testthat)

# Record the project root so helpers/tests can find R/, sql/ regardless of the
# working directory testthat switches to while running.
Sys.setenv(RWE_PROJECT_ROOT = normalizePath(getwd()))

test_dir(
  file.path("tests", "testthat"),
  reporter = "summary",
  stop_on_failure = TRUE
)
