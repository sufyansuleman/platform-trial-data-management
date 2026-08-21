# ---------------------------------------------------------------------------
# Conjugate posteriors.
#
# Everything here is closed form. No sampler, no chains, no convergence to
# diagnose. That is a deliberate constraint, argued in DEC-009: the repository
# claims that a historical analysis regenerates bit-identically, and that is a
# property of arithmetic but only a conditional property of a sampler.
#
# The models are the ones the statistical analysis plan pre-specifies:
#
#   * normal-normal for the continuous primary outcome
#   * beta-binomial for binary secondary outcomes
#
# Both are explainable to a committee in one line, which is the standard the
# specification sets.
# ---------------------------------------------------------------------------

#' Load the pre-specified priors
#'
#' @param path Path to the priors file.
#' @return A nested list.
load_priors <- function(path = project_path("config", "priors.yml")) {
  stopifnot(file.exists(path))
  yaml::read_yaml(path)
}

#' Load the pre-specified decision rules
#'
#' @param path Path to the decision rules file.
#' @return A nested list.
load_decision_rules <- function(path = project_path("config", "decision_rules.yml")) {
  stopifnot(file.exists(path))
  yaml::read_yaml(path)
}

#' Normal-normal conjugate posterior for a mean
#'
#' With a Normal(m0, s0^2) prior on the mean and a known observation standard
#' deviation, the posterior is Normal with precision equal to the sum of the
#' prior precision and the data precision. Written out rather than called from
#' a package so that a reader can check it against a textbook line by line.
#'
#' Assumes the observation standard deviation is known. The analysis plan
#' estimates it from the pooled data and holds it fixed; DEC-019 records why,
#' and what would make that wrong.
#'
#' @param values Observed outcome values.
#' @param prior_mean,prior_sd Prior on the mean.
#' @param sigma Known observation standard deviation.
#' @return A list with `n`, `mean`, `sd` and the observed summary statistics.
normal_posterior <- function(values, prior_mean, prior_sd, sigma) {
  values <- values[!is.na(values)]
  n <- length(values)

  if (n == 0) {
    return(list(n = 0L, mean = prior_mean, sd = prior_sd,
                observed_mean = NA_real_, observed_sd = NA_real_))
  }

  prior_precision <- 1 / prior_sd^2
  data_precision <- n / sigma^2
  posterior_precision <- prior_precision + data_precision

  posterior_mean <- (prior_mean * prior_precision + mean(values) * data_precision) /
    posterior_precision

  list(
    n = n,
    mean = posterior_mean,
    sd = sqrt(1 / posterior_precision),
    observed_mean = mean(values),
    observed_sd = if (n > 1) stats::sd(values) else NA_real_
  )
}

#' Posterior for the difference between two independent normal posteriors
#'
#' The difference of two independent normals is normal, so every quantity the
#' decision rules read has a closed form and no simulation is involved.
#'
#' `higher_is_better` reflects the outcome's direction: more days alive without
#' life support is better, more deaths is not. Getting this backwards would
#' invert every decision the trial makes, so it is explicit rather than assumed.
#'
#' @param posterior_a,posterior_b Outputs of [normal_posterior()].
#' @param equivalence_margin Margin for practical equivalence.
#' @param higher_is_better Whether a larger value favours arm A.
#' @return A list of posterior quantities.
normal_difference <- function(posterior_a, posterior_b, equivalence_margin,
                              higher_is_better = TRUE) {
  difference_mean <- posterior_a$mean - posterior_b$mean
  difference_sd <- sqrt(posterior_a$sd^2 + posterior_b$sd^2)

  # P(A better than B). With higher_is_better, that is P(difference > 0).
  probability_a_better <- if (higher_is_better) {
    stats::pnorm(0, difference_mean, difference_sd, lower.tail = FALSE)
  } else {
    stats::pnorm(0, difference_mean, difference_sd, lower.tail = TRUE)
  }

  probability_equivalent <-
    stats::pnorm(equivalence_margin, difference_mean, difference_sd) -
    stats::pnorm(-equivalence_margin, difference_mean, difference_sd)

  credible_interval <- stats::qnorm(c(0.025, 0.975), difference_mean, difference_sd)

  list(
    difference_mean = difference_mean,
    difference_sd = difference_sd,
    credible_interval_lower = credible_interval[1],
    credible_interval_upper = credible_interval[2],
    probability_a_better = probability_a_better,
    probability_equivalent = probability_equivalent
  )
}

#' Beta-binomial posterior for a proportion
#'
#' The posterior is Beta(alpha + events, beta + non-events). Exact, and the
#' whole model fits on one line.
#'
#' @param events Number of events.
#' @param n Number of observations.
#' @param prior_alpha,prior_beta Beta prior parameters.
#' @return A list with the posterior parameters and summaries.
beta_posterior <- function(events, n, prior_alpha, prior_beta) {
  alpha <- prior_alpha + events
  beta <- prior_beta + (n - events)
  interval <- stats::qbeta(c(0.025, 0.975), alpha, beta)

  list(
    n = n,
    events = events,
    alpha = alpha,
    beta = beta,
    mean = alpha / (alpha + beta),
    credible_interval_lower = interval[1],
    credible_interval_upper = interval[2],
    observed_proportion = if (n > 0) events / n else NA_real_
  )
}

#' Compare two beta posteriors
#'
#' P(proportion in A exceeds proportion in B) has no elementary closed form, so
#' it is computed by draws. The seed is fixed in `config/priors.yml` and set
#' here explicitly, because the reproducibility guarantee depends on this
#' number being identical on every run of the same cut.
#'
#' The caller's random state is restored afterwards, so calling this function
#' cannot change the results of anything else.
#'
#' @param posterior_a,posterior_b Outputs of [beta_posterior()].
#' @param draws Number of posterior draws.
#' @param seed Random seed.
#' @param higher_is_better Whether a larger proportion favours arm A.
#' @return A list of posterior quantities.
beta_difference <- function(posterior_a, posterior_b, draws = 100000,
                            seed = 20260821, higher_is_better = FALSE) {
  previous_seed <- if (exists(".Random.seed", envir = globalenv())) {
    get(".Random.seed", envir = globalenv())
  } else NULL
  on.exit({
    if (!is.null(previous_seed)) {
      assign(".Random.seed", previous_seed, envir = globalenv())
    }
  }, add = TRUE)

  set.seed(seed)
  draws_a <- stats::rbeta(draws, posterior_a$alpha, posterior_a$beta)
  draws_b <- stats::rbeta(draws, posterior_b$alpha, posterior_b$beta)
  difference <- draws_a - draws_b

  probability_a_better <- if (higher_is_better) {
    mean(difference > 0)
  } else {
    mean(difference < 0)
  }

  interval <- stats::quantile(difference, c(0.025, 0.975), names = FALSE)

  list(
    difference_mean = mean(difference),
    credible_interval_lower = interval[1],
    credible_interval_upper = interval[2],
    probability_a_better = probability_a_better
  )
}

#' Apply the pre-specified stopping rules
#'
#' Reads the thresholds from configuration rather than carrying its own copy,
#' so that the numbers a decision was made under are the ones a committee can
#' read in `config/decision_rules.yml`.
#'
#' Order matters. Equivalence is tested last: a domain that has met a
#' superiority threshold has answered its question, and reporting it as
#' equivalent because the difference is also small would be contradictory.
#'
#' @param comparison Output of [normal_difference()].
#' @param rules Decision rules from [load_decision_rules()].
#' @return A list with the decision and the quantity that triggered it.
apply_decision_rules <- function(comparison, rules = load_decision_rules()) {
  thresholds <- rules$thresholds
  probability <- comparison$probability_a_better

  if (probability > thresholds$superiority) {
    return(list(decision = "stop_superiority",
                triggered_by = "probability_a_better",
                value = probability,
                threshold = thresholds$superiority))
  }
  if (probability < thresholds$inferiority) {
    return(list(decision = "stop_inferiority",
                triggered_by = "probability_a_better",
                value = probability,
                threshold = thresholds$inferiority))
  }
  if (comparison$probability_equivalent > thresholds$practical_equivalence) {
    return(list(decision = "stop_equivalence",
                triggered_by = "probability_equivalent",
                value = comparison$probability_equivalent,
                threshold = thresholds$practical_equivalence))
  }
  list(decision = "continue", triggered_by = NA_character_,
       value = probability, threshold = NA_real_)
}

#' Updated allocation probabilities under response-adaptive randomisation
#'
#' Allocation is set proportional to each arm's posterior probability of being
#' best, then floored and renormalised.
#'
#' The floor is the part that matters. Without it, an early run of chance can
#' starve an arm of participants before the evidence is real, and a trial that
#' has stopped recruiting to an arm cannot gather the information it would need
#' to discover it was wrong.
#'
#' The floor is applied by CLAMPING, not by raising and renormalising. Raising
#' the smaller share to the floor and then dividing by the new total pushes it
#' straight back below the floor: with P(A better) = 0 and a floor of 0.40,
#' `pmax(c(0, 1), 0.4)` is `c(0.4, 1)`, which renormalises to `c(0.29, 0.71)`.
#' The arm the plan guarantees at least 40% of participants would have received
#' 29%, and nothing in the output would have shown it. Clamping the value into
#' `[floor, 1 - floor]` and taking the complement satisfies the guarantee by
#' construction, for two arms.
#'
#' Assumes exactly two arms, which every domain in this trial has. More arms
#' would need a genuine projection onto the constrained simplex, and the
#' renormalising shortcut would be wrong there too.
#'
#' @param probability_a_better P(arm A is better), from the comparison.
#' @param rules Decision rules, supplying the floor.
#' @return A named numeric vector of allocation probabilities summing to 1.
update_allocation <- function(probability_a_better, rules = load_decision_rules()) {
  floor_value <- rules$response_adaptive_randomisation$minimum_allocation
  stopifnot(floor_value <= 0.5)

  share_a <- min(max(probability_a_better, floor_value), 1 - floor_value)
  c(a = share_a, b = 1 - share_a)
}
