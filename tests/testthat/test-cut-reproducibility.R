# Data cuts.
#
# The claim these tests protect is the strongest one the repository makes:
# given a cut ID, the exact dataset a committee saw can be regenerated and
# proven identical. A claim like that is worthless unless something checks it
# on every commit.
#
# Built against the contract in docs/data_cut_sop.md.

# --- The inclusion rule -----------------------------------------------------

test_that("only participants whose 30-day window has closed are included", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()

  # P-000001 randomised on day 0, P-000002 on day 60. A cut 45 days in has
  # closed the first window and not even opened the second.
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  expect_equal(manifest$contents$participants, 1)
  data <- read_cut(manifest$cut_id, dir)
  expect_equal(unique(data$randomisation$participant_id), "P-000001")
})

test_that("a later cut includes both participants", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 100, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)
  expect_equal(manifest$contents$participants, 2)
})

test_that("a cut with nobody eligible fails loudly rather than writing an empty cut", {
  inputs <- cut_inputs()
  expect_error(
    make_cut(FIXTURE_DATE + 5, inputs$forms, inputs$findings, inputs$endpoint,
             dir = temp_cut_dir()),
    "No participant has completed follow-up"
  )
})

test_that("records with incomplete data are still included", {
  # Excluding a participant because their daily records are missing would
  # select the analysis population on data quality, which correlates with site,
  # which correlates with everything else.
  forms <- cut_fixture()
  forms$daily_icu <- forms$daily_icu[forms$daily_icu$icu_day != 1, ]  # gap
  inputs <- cut_inputs(forms)
  dir <- temp_cut_dir()

  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  expect_equal(manifest$contents$participants, 1)
  expect_gt(manifest$data_quality$total_unknown_days, 0)
  expect_equal(manifest$data_quality$endpoint_incomplete, 1)
})

# --- The manifest -----------------------------------------------------------

test_that("the manifest records everything needed to identify the cut", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  expect_equal(manifest$cut_id, cut_id_for(FIXTURE_DATE + 45))
  expect_equal(manifest$as_of_date, format(FIXTURE_DATE + 45))
  expect_true(nzchar(manifest$created_at))

  expect_true(all(c("rule_set_version", "trial_config_sha256", "r_version",
                    "package_versions", "trial_seed") %in%
                    names(manifest$provenance)))
  expect_equal(manifest$provenance$rule_set_version, rule_set_version())
})

test_that("every file in the cut is hashed with SHA-256", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  hashes <- unlist(manifest$files)
  expect_gt(length(hashes), 0)
  expect_true(all(nchar(hashes) == 64))

  files_on_disk <- list.files(file.path(dir, manifest$cut_id),
                              pattern = glob2rx("*.parquet"))
  expect_setequal(names(hashes), files_on_disk)
})

# --- Verification -----------------------------------------------------------

test_that("a freshly written cut verifies", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  result <- verify_cut(manifest$cut_id, dir)
  expect_true(result$verified)
  expect_length(result$mismatched, 0)
})

test_that("altering a byte of a frozen file breaks verification", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  target <- file.path(dir, manifest$cut_id, "outcome_30d.parquet")
  bytes <- readBin(target, "raw", file.info(target)$size)
  bytes[length(bytes) - 10] <- as.raw(xor(as.integer(bytes[length(bytes) - 10]), 1L))
  writeBin(bytes, target)

  result <- verify_cut(manifest$cut_id, dir)
  expect_false(result$verified)
  expect_true("outcome_30d.parquet" %in% result$mismatched)
})

test_that("removing a file breaks verification", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  file.remove(file.path(dir, manifest$cut_id, "findings.parquet"))
  result <- verify_cut(manifest$cut_id, dir)
  expect_false(result$verified)
  expect_true("findings.parquet" %in% result$missing)
})

test_that("adding a file the manifest does not know about breaks verification", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  arrow::write_parquet(data.frame(x = 1),
                       file.path(dir, manifest$cut_id, "extra.parquet"))
  result <- verify_cut(manifest$cut_id, dir)
  expect_false(result$verified)
  expect_true("extra.parquet" %in% result$unexpected)
})

test_that("reading a tampered cut is refused, not merely warned about", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  target <- file.path(dir, manifest$cut_id, "endpoint.parquet")
  arrow::write_parquet(data.frame(nonsense = 1), target)

  expect_error(read_cut(manifest$cut_id, dir),
               "failed verification")
})

# --- Reproduction: the headline claim ---------------------------------------

test_that("a cut regenerates byte for byte from the same inputs", {
  # This is the test the README points at. Can you regenerate the exact
  # dataset a committee saw a year ago? Yes, and here is the proof.
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  result <- reproduce_cut(manifest$cut_id, inputs$forms, inputs$findings,
                          inputs$endpoint, dir = dir)

  expect_true(result$reproduced)
  expect_true(all(result$comparison$identical))
})

test_that("reproduction detects a changed input", {
  # The guarantee must be falsifiable. If the inputs differ, the hashes must
  # differ too, or the check proves nothing.
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)

  altered <- inputs$forms
  altered$screening$weight_kg[1] <- altered$screening$weight_kg[1] + 5

  result <- reproduce_cut(manifest$cut_id, altered, inputs$findings,
                          inputs$endpoint, dir = dir)

  expect_false(result$reproduced)
  expect_true("screening.parquet" %in%
                result$comparison$file[!result$comparison$identical])
})

test_that("rebuilding a cut in place replaces it rather than merging", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  first <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                    inputs$endpoint, dir = dir)
  arrow::write_parquet(data.frame(x = 1),
                       file.path(dir, first$cut_id, "leftover.parquet"))

  second <- make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings,
                     inputs$endpoint, dir = dir)

  expect_false(file.exists(file.path(dir, second$cut_id, "leftover.parquet")))
  expect_true(verify_cut(second$cut_id, dir)$verified)
})

test_that("cuts can be listed", {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  make_cut(FIXTURE_DATE + 45, inputs$forms, inputs$findings, inputs$endpoint,
           dir = dir)
  make_cut(FIXTURE_DATE + 100, inputs$forms, inputs$findings, inputs$endpoint,
           dir = dir)

  listed <- list_cuts(dir)
  expect_equal(nrow(listed), 2)
  expect_true(all(c("cut_id", "as_of_date", "participants") %in% names(listed)))
})
