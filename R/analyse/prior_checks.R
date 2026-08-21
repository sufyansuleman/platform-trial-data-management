# ---------------------------------------------------------------------------
# Prior predictive checks and prior sensitivity.
#
# Two questions, asked at different times.
#
#   BEFORE the data: does this prior imply trials that could actually happen?
#   A prior that puts real mass on impossible results is wrong however
#   reasonable its parameters look in a table.
#
#   AFTER the data: does the DECISION change under a different prior? Not the
#   posterior, the decision. Three near-identical posteriors are reassuring and
#   uninformative; a domain that stops for superiority under one prior and
#   continues under another is the finding, and has to be reported as one.
#
# Required by docs/statistical_analysis_plan.md section 9.
# ---------------------------------------------------------------------------

#' Simulate trials from the priors alone
#'
#' Draws arm means from the prior and reports what range of trial results the
#' prior considers plausible before seeing any data. The primary outcome is
#' bounded at 0 and 30 days, so any appreciable prior mass outside that range
#' is a prior asserting that impossible trials are likely.
#'
#' @param priors Priors from [load_priors()].
#' @param draws Number of simulated trials.
#' @param seed Seed, so the check is reproducible.
#' @return A data frame of simulated arm means and differences.
prior_predictive_draws <- function(priors, draws = 10000, seed = NULL) {
  seed <- seed %||% priors$posterior$seed
  previous_seed <- if (exists(".Random.seed", envir = globalenv())) {
    get(".Random.seed", envir = globalenv())
  } else NULL
  on.exit({
    if (!is.null(previous_seed)) {
      assign(".Random.seed", previous_seed, envir = globalenv())
    }
  }, add = TRUE)
  set.seed(seed)

  specification <- priors$primary_outcome$arm_mean_prior
  arm_a <- stats::rnorm(draws, specification$mean, specification$sd)
  arm_b <- stats::rnorm(draws, specification$mean, specification$sd)

  mortality <- stats::rbeta(draws, priors$mortality$arm_prior$alpha,
                            priors$mortality$arm_prior$beta)

  data.frame(
    arm_a_mean = arm_a,
    arm_b_mean = arm_b,
    difference = arm_a - arm_b,
    mortality = mortality,
    stringsAsFactors = FALSE
  )
}

#' Summarise whether the priors imply plausible trials
#'
#' Reports the proportion of prior-implied trials that fall outside the range
#' the outcome can physically take. A weakly informative prior is expected to
#' put *some* mass outside the bounds, since it is deliberately wide; the check
#' is that the bulk of it is inside, and that the implied treatment effects are
#' not routinely larger than any critical care intervention has ever produced.
#'
#' @param priors Priors from [load_priors()].
#' @param window_days Maximum value the primary outcome can take.
#' @param implausible_effect_days A treatment effect this large has never been
#'   observed for this outcome; the check reports how often the prior implies
#'   one.
#' @param draws,seed Passed to [prior_predictive_draws()].
#' @return A one-row data frame of diagnostics.
prior_predictive_check <- function(priors, window_days = 30,
                                   implausible_effect_days = 10,
                                   draws = 10000, seed = NULL) {
  simulated <- prior_predictive_draws(priors, draws, seed)

  outside_bounds <- mean(simulated$arm_a_mean < 0 | simulated$arm_a_mean > window_days)
  implausible <- mean(abs(simulated$difference) > implausible_effect_days)

  data.frame(
    draws = nrow(simulated),
    mean_arm_mean = round(mean(simulated$arm_a_mean), 2),
    prior_effect_mean = round(mean(simulated$difference), 3),
    prior_effect_sd = round(stats::sd(simulated$difference), 2),
    proportion_outside_outcome_bounds = round(outside_bounds, 3),
    proportion_effect_implausibly_large = round(implausible, 3),
    mean_prior_mortality = round(mean(simulated$mortality), 3),
    stringsAsFactors = FALSE
  )
}

#' Rebuild the priors object under one of the sensitivity prior sets
#'
#' Only the quantities the sensitivity analysis varies are replaced: the width
#' of the treatment-effect prior and the strength of the mortality prior. The
#' centre is not varied, because a sensitivity analysis that moves the centre
#' of a treatment-effect prior is not testing robustness, it is testing a
#' different pre-specification.
#'
#' @param priors Base priors.
#' @param prior_set One element of `priors$sensitivity_priors`.
#' @return A modified copy of `priors`.
apply_prior_set <- function(priors, prior_set) {
  priors$primary_outcome$arm_mean_prior$sd <- prior_set$arm_mean_sd
  priors$mortality$arm_prior$alpha <- prior_set$mortality_alpha
  priors$mortality$arm_prior$beta <- prior_set$mortality_beta
  priors
}

#' Recompute every decision under each pre-specified prior set
#'
#' The headline column is `decision`. If it is the same in every row, the
#' conclusion does not depend on the prior. If it differs, that is the result
#' to report, and it must not be buried under the posteriors.
#'
#' @param cut_id Cut to analyse.
#' @param cuts_dir Directory holding the cuts.
#' @param priors Base priors, carrying the sensitivity sets.
#' @param rules Decision rules.
#' @return A data frame, one row per domain per prior set.
prior_sensitivity <- function(cut_id, cuts_dir = project_path("data", "cuts"),
                              priors = load_priors(),
                              rules = load_decision_rules()) {
  verification <- verify_cut(cut_id, cuts_dir)
  if (!verification$verified) {
    stop("Refusing to analyse cut '", cut_id, "': manifest verification failed.",
         call. = FALSE)
  }
  cut_data <- read_cut(cut_id, cuts_dir, verify = FALSE)
  domains <- sort(unique(cut_data$randomisation$domain))

  rows <- list()
  for (domain in domains) {
    data <- analysis_dataset(cut_data, domain)
    if (!nrow(data)) next

    for (prior_set in priors$sensitivity_priors) {
      result <- analyse_domain(data, apply_prior_set(priors, prior_set), rules)
      rows[[length(rows) + 1]] <- data.frame(
        domain = domain,
        prior_set = prior_set$id,
        prior_label = prior_set$label,
        treatment_effect_prior_sd = prior_set$arm_mean_sd,
        difference = round(result$primary$comparison$difference_mean, 3),
        ci_lower = round(result$primary$comparison$credible_interval_lower, 2),
        ci_upper = round(result$primary$comparison$credible_interval_upper, 2),
        p_a_better = round(result$primary$comparison$probability_a_better, 4),
        p_equivalent = round(result$primary$comparison$probability_equivalent, 4),
        decision = result$primary$decision$decision,
        stringsAsFactors = FALSE
      )
    }
  }

  do.call(rbind, rows)
}

#' Does the decision survive the choice of prior?
#'
#' Collapses the sensitivity table to the question a committee actually asks.
#'
#' @param sensitivity Output of [prior_sensitivity()].
#' @return A data frame, one row per domain.
decision_robustness <- function(sensitivity) {
  sensitivity |>
    dplyr::group_by(domain) |>
    dplyr::summarise(
      decisions = paste(sort(unique(decision)), collapse = " / "),
      distinct_decisions = dplyr::n_distinct(decision),
      robust = dplyr::n_distinct(decision) == 1,
      .groups = "drop"
    ) |>
    as.data.frame()
}
