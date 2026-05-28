# testthat entry point — runs the suite under tests/testthat/.
# Invoked by `make test` and by CI (.github/workflows/ci.yml).
#
# Status: SCAFFOLD — wires up testthat; individual tests are stubs.

library(testthat)

test_dir(
  file.path("tests", "testthat"),
  reporter = "summary",
  stop_on_failure = TRUE
)
