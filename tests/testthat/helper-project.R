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

# Config paths resolve against the project root via project_path(), so tests
# do not need to change the working directory to find them.
for (file in list.files(file.path(ROOT, "R"), pattern = "[.]R$",
                        recursive = TRUE, full.names = TRUE)) {
  source(file)
}

#' Load the trial config, which resolves its own path from the project root.
test_config <- function() {
  load_trial_config()
}

#' A single-row site definition, for testing conversions in isolation.
test_site <- function(site_id = "DK-01", cfg = test_config()) {
  sites <- resolve_sites(cfg)
  sites[sites$site_id == site_id, ]
}
