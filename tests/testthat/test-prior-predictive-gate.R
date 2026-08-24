# The prior predictive gate.
#
# The control that turns "remember to check the prior before the plan takes
# effect" into a state the analysis engine refuses to proceed without.
#
# Required by DEC-023a.

temp_priors <- function(arm_mean_sd) {
  priors <- load_priors()
  priors$primary_outcome$arm_mean_prior$sd <- arm_mean_sd
  path <- tempfile(fileext = ".yml")
  yaml::write_yaml(priors, path)
  path
}

test_that("the shipped priors have a recorded passing check", {
  # If this fails, the pipeline cannot run an analysis, which is the point.
  expect_silent(assert_prior_predictive_passed())
  record <- read_prior_predictive_record()
  expect_equal(record$status, "pass")
  expect_equal(record$priors_version, load_priors()$version)
})

test_that("the recorded check is bound to the exact priors it was run against", {
  record <- read_prior_predictive_record()
  expect_equal(record$priors_sha256,
               file_sha256(project_path("config", "priors.yml")))
})

test_that("the gate refuses when no check has ever been recorded", {
  expect_error(
    assert_prior_predictive_passed(record_path = tempfile(fileext = ".yml")),
    "no prior predictive check has been recorded"
  )
})

test_that("the gate refuses when a prior was edited after the check", {
  # The condition human review misses most easily: the record looks fine, and
  # describes priors that are no longer the ones in force.
  edited <- temp_priors(arm_mean_sd = 3)
  expect_error(
    assert_prior_predictive_passed(priors_path = edited),
    "priors have changed since the prior"
  )
})

test_that("the gate refuses when the recorded check failed", {
  failing <- record_prior_predictive_check(
    priors = { p <- load_priors(); p$primary_outcome$arm_mean_prior$sd <- 30; p },
    priors_path = project_path("config", "priors.yml"),
    output_path = (record <- tempfile(fileext = ".yml"))
  )
  expect_equal(failing$status, "fail")

  expect_error(
    assert_prior_predictive_passed(record_path = record),
    "did not pass"
  )
})

test_that("a prior implying impossible trials fails the check", {
  # sd 30 on an outcome bounded at 0 to 30 days puts most of its mass outside
  # the range the outcome can take.
  priors <- load_priors()
  priors$primary_outcome$arm_mean_prior$sd <- 30
  result <- prior_predictive_check(priors)

  criteria <- prior_predictive_criteria()
  expect_gt(result$proportion_outside_outcome_bounds,
            criteria$max_proportion_outside_bounds)
})

test_that("the amended prior passes both criteria", {
  result <- prior_predictive_check(load_priors())
  criteria <- prior_predictive_criteria()
  expect_lte(result$proportion_outside_outcome_bounds,
             criteria$max_proportion_outside_bounds)
  expect_lte(result$proportion_effect_implausibly_large,
             criteria$max_proportion_effect_implausible)
})

test_that("the treatment effect prior is centred on no difference", {
  # Whatever its width, it must not favour either arm.
  result <- prior_predictive_check(load_priors(), draws = 40000)
  expect_lt(abs(result$prior_effect_mean), 0.2)
})

test_that("the analysis engine refuses to run when the gate fails", {
  # The end to end control: not merely that the check exists, but that the
  # engine will not start without it.
  cut <- analysis_cut()
  broken_record <- tempfile(fileext = ".yml")
  record_prior_predictive_check(
    priors = { p <- load_priors(); p$primary_outcome$arm_mean_prior$sd <- 40; p },
    output_path = broken_record
  )

  expect_error(
    run_adaptive_analysis(cut$cut_id, cuts_dir = cut$dir, output_dir = tempdir(),
                          prior_record_path = broken_record),
    "did not pass"
  )
})
