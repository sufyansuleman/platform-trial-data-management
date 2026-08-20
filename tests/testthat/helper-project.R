# Sourced automatically by testthat before any test file.
#
# There is no package structure in this repository, deliberately: a reader
# should be able to open any file in R/ and run it. Tests therefore source the
# same files the pipeline does, from the project root.

project_root <- function() {
  path <- normalizePath(".", winslash = "/")
  while (!file.exists(file.path(path, "_targets.R"))) {
    parent <- dirname(path)
    if (identical(parent, path)) stop("Could not locate the project root.")
    path <- parent
  }
  path
}

ROOT <- project_root()

# Several functions resolve config paths relative to the project root, which is
# how they are called from the pipeline. Running tests from the project root
# keeps those calls working without threading a path argument through every
# function purely for the benefit of the test suite.
setwd(ROOT)
for (file in list.files(file.path(ROOT, "R"), pattern = "[.]R$",
                        recursive = TRUE, full.names = TRUE)) {
  source(file)
}

#' Load the trial config from the project root regardless of working directory.
test_config <- function() {
  load_trial_config(file.path(ROOT, "config", "trial.yml"))
}

#' A single-row site definition, for testing conversions in isolation.
test_site <- function(site_id = "DK-01", cfg = test_config()) {
  sites <- resolve_sites(cfg)
  sites[sites$site_id == site_id, ]
}
