# Allocation updates and reconciliation.
#
# The failure this guards against produces no error, no warning, and a
# perfectly plausible allocation ratio. These tests assert both halves of that:
# that reconciliation catches it, and that nothing else does.

allocation_fixture <- function(n_per_site = 200, failing_site = "DK-01",
                               specified = 0.6, realised_at_failing = 0.5,
                               seed = 11) {
  set.seed(seed)
  sites <- c("DK-01", "DK-02", "DK-03")
  start <- as.Date("2025-01-01")

  rows <- lapply(sites, function(site) {
    probability <- if (site == failing_site) realised_at_failing else specified
    arm <- sample(c("liberal", "restrictive"), n_per_site, replace = TRUE,
                  prob = c(probability, 1 - probability))
    data.frame(
      randomisation_id = sprintf("RND-%s-%04d", site, seq_len(n_per_site)),
      participant_id = sprintf("P-%s-%04d", site, seq_len(n_per_site)),
      site_id = site,
      domain = "FLUID",
      arm = arm,
      randomisation_datetime = as.POSIXct(start + seq_len(n_per_site) %% 300,
                                          tz = "UTC"),
      # The specified ratio is recorded at every site, including the one that
      # never applied it.
      allocation_ratio = "3:2",
      entry_date = start + 1,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

specified_fixture <- function(probability = 0.6) {
  data.frame(
    domain = "FLUID",
    arm = c("liberal", "restrictive"),
    probability = c(probability, 1 - probability),
    stringsAsFactors = FALSE
  )
}

# --- The failure is silent everywhere else ----------------------------------

test_that("the failing site records the same allocation ratio as everyone else", {
  # This is what makes the failure invisible. The field records what was
  # SPECIFIED, and the specification went to every site.
  randomisation <- allocation_fixture()
  ratios <- tapply(randomisation$allocation_ratio, randomisation$site_id, unique)
  expect_equal(length(unique(unlist(ratios))), 1)
})

test_that("the failing site's realised split is plausible in isolation", {
  # A 1:1 split is an entirely ordinary thing for a randomised trial to show.
  # Nothing about the number itself is suspicious.
  randomisation <- allocation_fixture()
  failing <- randomisation[randomisation$site_id == "DK-01", ]
  realised <- mean(failing$arm == "liberal")
  expect_gt(realised, 0.4)
  expect_lt(realised, 0.6)
})

test_that("no validation rule fires on the misallocated records", {
  # The records are complete, internally consistent and schema-conformant.
  # There is nothing for a row-level rule to object to.
  forms <- fixture_forms()
  forms$randomisation$allocation_ratio <- "3:2"
  expect_equal(nrow(validate_fixture(forms)), 0)
})

# --- Reconciliation catches it ----------------------------------------------

test_that("reconciliation flags the site whose update never took effect", {
  randomisation <- allocation_fixture()
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2025-01-01"), as.Date("2026-01-01"))

  expect_true(result$flagged[result$site_id == "DK-01"])
  expect_equal(sum(result$flagged), 1)
})

test_that("reconciliation leaves compliant sites alone", {
  randomisation <- allocation_fixture()
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2025-01-01"), as.Date("2026-01-01"))
  compliant <- result[result$site_id != "DK-01", ]
  expect_false(any(compliant$flagged))
})

test_that("a trial where every site complied flags nobody", {
  # The check must be falsifiable in the other direction too: if it flags a
  # site when nothing is wrong, it is worthless.
  randomisation <- allocation_fixture(realised_at_failing = 0.6)
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2025-01-01"), as.Date("2026-01-01"))
  expect_equal(sum(result$flagged), 0)
})

test_that("a small site cannot be flagged on a modest deviation", {
  # Correct behaviour, not a limitation to apologise for. Twelve participants
  # cannot demonstrate a ten point misallocation, and a test that claimed
  # otherwise would generate accusations it could not support.
  randomisation <- allocation_fixture(n_per_site = 12)
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2025-01-01"), as.Date("2026-01-01"))
  expect_equal(sum(result$flagged), 0)
})

test_that("only randomisations inside the period are reconciled", {
  randomisation <- allocation_fixture()
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2030-01-01"), as.Date("2030-12-31"))
  expect_equal(nrow(result), 0)
})

test_that("pooling refuses when domains specify different probabilities", {
  # Pooling would make the count Poisson-binomial rather than binomial, and
  # the test would be quietly wrong. Refusing is the honest response.
  randomisation <- allocation_fixture()
  randomisation$domain[1:100] <- "ANTICOAG"
  mixed <- rbind(
    specified_fixture(0.6),
    data.frame(domain = "ANTICOAG", arm = c("intermediate_dose", "standard_dose"),
               probability = c(0.75, 0.25), stringsAsFactors = FALSE)
  )
  expect_error(
    reconcile_allocation(randomisation, mixed, as.Date("2025-01-01"),
                         as.Date("2026-01-01")),
    "Cannot pool domains"
  )
})

# --- Deviations become findings ---------------------------------------------

test_that("a flagged deviation becomes a critical finding", {
  randomisation <- allocation_fixture()
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2025-01-01"), as.Date("2026-01-01"))
  sites <- resolve_sites(test_config())
  findings <- allocation_findings(result, sites)

  expect_equal(nrow(findings), 1)
  expect_equal(findings$severity, "critical")
  expect_equal(findings$site_id, "DK-01")
  expect_equal(findings$rule_id, "ALC-001")
  # It joins the same findings table as everything else, so it reaches the
  # central report through machinery that already exists.
  expect_setequal(names(findings), names(empty_findings()))
})

test_that("no deviations produce no findings, with the right columns", {
  randomisation <- allocation_fixture(realised_at_failing = 0.6)
  result <- reconcile_allocation(randomisation, specified_fixture(),
                                 as.Date("2025-01-01"), as.Date("2026-01-01"))
  findings <- allocation_findings(result, resolve_sites(test_config()))
  expect_equal(nrow(findings), 0)
  expect_setequal(names(findings), names(empty_findings()))
})

# --- The update artefact ----------------------------------------------------

test_that("an emitted allocation update carries a checksum that verifies", {
  dir <- file.path(tempdir(), paste0("alloc-", as.integer(runif(1, 1, 1e9))))
  update <- emit_allocation_update(specified_fixture(), as.Date("2025-06-01"),
                                   source_id = "interim-test", dir = dir)

  expect_equal(update$update_id, "ALU-20250601")
  expect_equal(nchar(update$checksum), 64)
  expect_silent(read_allocation_update(update$update_id, dir))
})

test_that("an altered allocation update fails its own checksum", {
  # Never a bare number for somebody to retype: the value that arrives must be
  # checkable against the value that left.
  dir <- file.path(tempdir(), paste0("alloc-", as.integer(runif(1, 1, 1e9))))
  update <- emit_allocation_update(specified_fixture(), as.Date("2025-06-01"),
                                   source_id = "interim-test", dir = dir)

  path <- file.path(dir, paste0(update$update_id, ".json"))
  tampered <- jsonlite::read_json(path, simplifyVector = TRUE)
  tampered$domains$FLUID$probabilities <- c(0.9, 0.1)
  jsonlite::write_json(tampered, path, auto_unbox = TRUE, pretty = TRUE, digits = NA)

  expect_error(read_allocation_update(update$update_id, dir),
               "fails its own checksum")
})

# --- Against the real pipeline data -----------------------------------------

test_that("the injected allocation failure is detected in the pipeline data", {
  skip_if_not(file.exists(project_path("_targets", "objects", "conformed_forms")),
              "pipeline has not been run")

  cfg <- load_trial_config()
  forms <- targets::tar_read(conformed_forms, store = project_path("_targets"))
  spec <- specified_allocation(cfg)

  result <- reconcile_allocation(
    forms$randomisation, spec, attr(spec, "effective_date"),
    max(as.Date(forms$randomisation$randomisation_datetime), na.rm = TRUE)
  )

  ids <- vapply(cfg$defects, function(d) d$id, character(1))
  failing <- unlist(cfg$defects[[which(ids == "D13")]]$failing_sites)

  expect_true(all(failing %in% result$site_id[result$flagged]))
  expect_equal(sum(result$flagged), length(failing))
})
