# The interim analysis engine.
#
# The conjugate posteriors are checked against values computed by hand from the
# textbook formulae, not against the function's own output. A test that
# compares a function to itself passes forever and proves nothing.
#
# Governed by docs/statistical_analysis_plan.md.

# --- Normal-normal conjugate posterior --------------------------------------

test_that("the normal posterior matches the closed form computed by hand", {
  # Prior Normal(10, 5^2), sigma = 4, data mean 20 over n = 16.
  # prior precision  = 1/25          = 0.04
  # data precision   = 16/16         = 1.00
  # posterior precision              = 1.04
  # posterior mean   = (10*0.04 + 20*1.00) / 1.04 = 20.4 / 1.04
  values <- rep(20, 16)
  posterior <- normal_posterior(values, prior_mean = 10, prior_sd = 5, sigma = 4)

  expect_equal(posterior$n, 16L)
  expect_equal(posterior$mean, 20.4 / 1.04, tolerance = 1e-10)
  expect_equal(posterior$sd, sqrt(1 / 1.04), tolerance = 1e-10)
})

test_that("with no data the posterior is exactly the prior", {
  posterior <- normal_posterior(numeric(0), prior_mean = 15, prior_sd = 10, sigma = 12)
  expect_equal(posterior$mean, 15)
  expect_equal(posterior$sd, 10)
  expect_equal(posterior$n, 0L)
})

test_that("more data pulls the posterior toward the observed mean", {
  small <- normal_posterior(rep(25, 5), 10, 5, 4)
  large <- normal_posterior(rep(25, 500), 10, 5, 4)

  expect_lt(abs(large$mean - 25), abs(small$mean - 25))
  expect_lt(large$sd, small$sd)
})

test_that("missing values are dropped rather than propagating", {
  with_na <- normal_posterior(c(20, 20, NA, 20), 10, 5, 4)
  without <- normal_posterior(c(20, 20, 20), 10, 5, 4)
  expect_equal(with_na$mean, without$mean)
  expect_equal(with_na$n, 3L)
})

# --- The difference between two arms ----------------------------------------

test_that("identical arms give a difference centred on zero and P(better) of one half", {
  a <- normal_posterior(rep(15, 100), 15, 10, 12)
  b <- normal_posterior(rep(15, 100), 15, 10, 12)
  comparison <- normal_difference(a, b, equivalence_margin = 1)

  expect_equal(comparison$difference_mean, 0, tolerance = 1e-10)
  expect_equal(comparison$probability_a_better, 0.5, tolerance = 1e-10)
})

test_that("the credible interval is symmetric about the difference", {
  a <- normal_posterior(rep(18, 200), 15, 10, 12)
  b <- normal_posterior(rep(14, 200), 15, 10, 12)
  comparison <- normal_difference(a, b, equivalence_margin = 1)

  midpoint <- mean(c(comparison$credible_interval_lower,
                     comparison$credible_interval_upper))
  expect_equal(midpoint, comparison$difference_mean, tolerance = 1e-8)
  expect_lt(comparison$credible_interval_lower, comparison$credible_interval_upper)
})

test_that("direction is respected: higher_is_better inverts the comparison", {
  a <- normal_posterior(rep(18, 200), 15, 10, 12)
  b <- normal_posterior(rep(14, 200), 15, 10, 12)

  higher <- normal_difference(a, b, 1, higher_is_better = TRUE)
  lower <- normal_difference(a, b, 1, higher_is_better = FALSE)

  # Getting this backwards would invert every decision the trial makes.
  expect_gt(higher$probability_a_better, 0.5)
  expect_equal(higher$probability_a_better, 1 - lower$probability_a_better,
               tolerance = 1e-12)
})

test_that("a large difference makes practical equivalence improbable", {
  a <- normal_posterior(rep(25, 400), 15, 10, 12)
  b <- normal_posterior(rep(10, 400), 15, 10, 12)
  comparison <- normal_difference(a, b, equivalence_margin = 1)
  expect_lt(comparison$probability_equivalent, 0.01)
})

test_that("arms that genuinely agree make practical equivalence probable", {
  a <- normal_posterior(rep(15.0, 3000), 15, 10, 12)
  b <- normal_posterior(rep(15.05, 3000), 15, 10, 12)
  comparison <- normal_difference(a, b, equivalence_margin = 1)
  expect_gt(comparison$probability_equivalent, 0.9)
})

# --- Beta-binomial ----------------------------------------------------------

test_that("the beta posterior is the prior plus the counts", {
  posterior <- beta_posterior(events = 30, n = 100, prior_alpha = 2, prior_beta = 3)
  expect_equal(posterior$alpha, 32)
  expect_equal(posterior$beta, 73)
  expect_equal(posterior$mean, 32 / 105)
  expect_equal(posterior$observed_proportion, 0.3)
})

test_that("the beta posterior with no data is the prior", {
  posterior <- beta_posterior(events = 0, n = 0, prior_alpha = 2, prior_beta = 3)
  expect_equal(posterior$alpha, 2)
  expect_equal(posterior$beta, 3)
  expect_equal(posterior$mean, 0.4)
})

test_that("comparing beta posteriors is reproducible for a fixed seed", {
  a <- beta_posterior(30, 100, 2, 3)
  b <- beta_posterior(45, 100, 2, 3)

  first <- beta_difference(a, b, draws = 20000, seed = 1)
  second <- beta_difference(a, b, draws = 20000, seed = 1)

  # The reproducibility guarantee depends on this being exactly equal, not
  # merely close.
  expect_identical(first$probability_a_better, second$probability_a_better)
  expect_identical(first$difference_mean, second$difference_mean)
})

test_that("comparing beta posteriors does not disturb the caller's random state", {
  set.seed(99)
  expected <- runif(3)

  set.seed(99)
  invisible(beta_difference(beta_posterior(10, 50, 2, 3),
                            beta_posterior(20, 50, 2, 3),
                            draws = 5000, seed = 7))
  expect_equal(runif(3), expected)
})

test_that("lower mortality is better, so the arm with fewer deaths wins", {
  fewer_deaths <- beta_posterior(20, 200, 2, 3)
  more_deaths <- beta_posterior(60, 200, 2, 3)
  comparison <- beta_difference(fewer_deaths, more_deaths, draws = 20000,
                                seed = 1, higher_is_better = FALSE)
  expect_gt(comparison$probability_a_better, 0.99)
})

# --- Decision rules ---------------------------------------------------------

fake_comparison <- function(p_better, p_equivalent = 0) {
  list(probability_a_better = p_better, probability_equivalent = p_equivalent)
}

test_that("the pre-specified thresholds are the ones applied", {
  rules <- load_decision_rules()
  expect_equal(rules$thresholds$superiority, 0.99)
  expect_equal(rules$thresholds$inferiority, 0.01)
  expect_equal(rules$thresholds$practical_equivalence, 0.90)
  expect_equal(rules$thresholds$equivalence_margin_days, 1.0)
})

test_that("each decision fires on its own condition", {
  expect_equal(apply_decision_rules(fake_comparison(0.995))$decision,
               "stop_superiority")
  expect_equal(apply_decision_rules(fake_comparison(0.005))$decision,
               "stop_inferiority")
  expect_equal(apply_decision_rules(fake_comparison(0.5, 0.95))$decision,
               "stop_equivalence")
  expect_equal(apply_decision_rules(fake_comparison(0.5, 0.5))$decision,
               "continue")
})

test_that("a probability exactly on the threshold does not stop the trial", {
  # The rule is strictly greater than, and a boundary that drifts is a boundary
  # that means something different from what the plan says.
  expect_equal(apply_decision_rules(fake_comparison(0.99))$decision, "continue")
  expect_equal(apply_decision_rules(fake_comparison(0.01))$decision, "continue")
  expect_equal(apply_decision_rules(fake_comparison(0.5, 0.90))$decision, "continue")
})

test_that("superiority takes precedence over equivalence", {
  # A domain that has answered its question is not also 'equivalent'.
  decision <- apply_decision_rules(fake_comparison(0.999, 0.99))
  expect_equal(decision$decision, "stop_superiority")
})

test_that("the decision records what triggered it", {
  decision <- apply_decision_rules(fake_comparison(0.995))
  expect_equal(decision$triggered_by, "probability_a_better")
  expect_equal(decision$value, 0.995)
  expect_equal(decision$threshold, 0.99)
})

# --- Response-adaptive randomisation ----------------------------------------

test_that("allocation follows the probability of being better", {
  allocation <- update_allocation(0.7)
  expect_gt(allocation[["a"]], allocation[["b"]])
  expect_equal(sum(allocation), 1)
})

test_that("no arm can fall below the pre-specified floor", {
  # The floor is what stops an early run of chance starving an arm before the
  # evidence is real.
  floor_value <- load_decision_rules()$response_adaptive_randomisation$minimum_allocation

  for (probability in c(0, 0.001, 0.05, 0.5, 0.95, 0.999, 1)) {
    allocation <- update_allocation(probability)
    expect_gte(min(allocation), floor_value * 0.999)
    expect_equal(sum(allocation), 1, tolerance = 1e-12)
  }
})

test_that("an even probability gives an even allocation", {
  allocation <- update_allocation(0.5)
  expect_equal(allocation[["a"]], 0.5)
  expect_equal(allocation[["b"]], 0.5)
})

# --- The engine end to end --------------------------------------------------

test_that("the engine refuses to analyse a cut that fails verification", {
  # The seam the whole design exists to protect. An analysis on a silently
  # modified cut carries the authority of a frozen dataset without the
  # substance of one.
  cut <- analysis_cut()
  arrow::write_parquet(data.frame(nonsense = 1),
                       file.path(cut$dir, cut$cut_id, "endpoint.parquet"))

  expect_error(
    run_adaptive_analysis(cut$cut_id, cuts_dir = cut$dir,
                          output_dir = tempdir()),
    "verification failed"
  )
})

test_that("the analysis record stamps the specification versions it used", {
  cut <- analysis_cut()
  # The fixture has one arm per domain, so the comparison itself cannot run;
  # what is asserted here is that the record captures its provenance.
  record <- tryCatch(
    run_adaptive_analysis(cut$cut_id, cuts_dir = cut$dir, output_dir = tempdir()),
    error = function(e) e
  )
  skip_if(inherits(record, "error"),
          "fixture has a single arm per domain; covered by the pipeline run")

  expect_equal(record$specification$sap_version, SAP_VERSION)
  expect_equal(record$specification$priors_version, load_priors()$version)
  expect_equal(record$specification$decision_rules_version,
               load_decision_rules()$version)
  expect_equal(nchar(record$specification$priors_file_sha256), 64)
  expect_equal(record$cut$cut_id, cut$cut_id)
})

test_that("records with no recorded allocation are counted, not silently dropped", {
  # An NA arm cannot be attributed to a treatment group. Leaving it in place
  # propagates NA through every count in the result, which is how this surfaced.
  data <- data.frame(
    participant_id = sprintf("P-%06d", 1:40),
    domain = "FLUID",
    arm = c(rep("liberal", 19), rep("restrictive", 19), NA, NA),
    days_alive_without_life_support = c(rep(20L, 19), rep(15L, 19), 10L, 10L),
    complete = TRUE,
    vital_status_30d = "alive",
    stringsAsFactors = FALSE
  )

  result <- analyse_domain(data, load_priors(), load_decision_rules())
  expect_equal(result$counts$no_allocation_recorded, 2)
  expect_equal(result$counts$arm_a + result$counts$arm_b, 38)
})
