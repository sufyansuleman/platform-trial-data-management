# ---------------------------------------------------------------------------
# The prior predictive gate.
#
# A prior predictive check belongs at SAP finalisation, as a condition of the
# plan becoming effective. Run afterwards it is a diagnostic, and a diagnostic
# is something a person is supposed to remember to act on.
#
# This file makes it pipeline behaviour instead. run_adaptive_analysis()
# refuses to run unless the priors it is about to use have a recorded, passing
# prior predictive check, recorded against those exact priors. Forgetting is no
# longer possible; the analysis simply will not start.
#
# The same pattern as any other guard worth having: convert an obligation
# somebody is meant to honour into a state the code checks.
# ---------------------------------------------------------------------------

#' Acceptance criteria for a prior predictive check
#'
#' Stated here as the operational definition of "the prior implies trials that
#' could actually happen". Both are properties of the PRIOR ALONE and can be
#' evaluated before any data exists, which is what makes the check a legitimate
#' gate at finalisation rather than a post-hoc adjustment.
#'
#' @return A named list of thresholds.
prior_predictive_criteria <- function() {
  list(
    # The outcome is bounded at 0 and 30 days. A prior is allowed some mass
    # outside that, since a weakly informative prior is deliberately wide, but
    # not a large share of it.
    max_proportion_outside_bounds = 0.10,

    # A treatment effect above 10 days on this outcome has never been observed
    # in critical care. A prior that expects one more often than a quarter of
    # the time is asserting something no evidence supports.
    max_proportion_effect_implausible = 0.25,
    implausible_effect_days = 10
  )
}

#' Run the prior predictive check and record the result
#'
#' Writes `config/prior_predictive_record.yml`, which is the artefact the gate
#' reads. The record is bound to a hash of the priors file, so changing a prior
#' invalidates the record rather than silently inheriting the old verdict.
#'
#' Intended to be run at SAP finalisation, before any analysis.
#'
#' @param priors Priors to check.
#' @param priors_path Path to the priors file, hashed into the record.
#' @param output_path Where to write the record.
#' @param criteria Acceptance criteria.
#' @return The record, invisibly.
record_prior_predictive_check <- function(
    priors = load_priors(),
    priors_path = project_path("config", "priors.yml"),
    output_path = project_path("config", "prior_predictive_record.yml"),
    criteria = prior_predictive_criteria()) {

  result <- prior_predictive_check(
    priors,
    implausible_effect_days = criteria$implausible_effect_days
  )

  passed_bounds <- result$proportion_outside_outcome_bounds <=
    criteria$max_proportion_outside_bounds
  passed_effect <- result$proportion_effect_implausibly_large <=
    criteria$max_proportion_effect_implausible

  record <- list(
    priors_version = priors$version,
    priors_sha256 = file_sha256(priors_path),
    checked_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    criteria = criteria,
    results = list(
      proportion_outside_outcome_bounds = result$proportion_outside_outcome_bounds,
      proportion_effect_implausibly_large = result$proportion_effect_implausibly_large,
      prior_effect_sd = result$prior_effect_sd
    ),
    outcome = list(
      bounds_criterion_met = passed_bounds,
      effect_criterion_met = passed_effect
    ),
    status = if (passed_bounds && passed_effect) "pass" else "fail"
  )

  yaml::write_yaml(record, output_path)
  invisible(record)
}

#' Read the recorded prior predictive check
#'
#' @param path Path to the record.
#' @return The record, or NULL if none exists.
read_prior_predictive_record <- function(
    path = project_path("config", "prior_predictive_record.yml")) {
  if (!file.exists(path)) return(NULL)
  yaml::read_yaml(path)
}

#' Refuse to proceed unless the priors have a passing recorded check
#'
#' Fails for three distinct reasons, each reported distinctly, because they
#' call for different remedies:
#'
#'   * no record exists, so the check was never run;
#'   * the record does not match the current priors, so a prior was edited
#'     after the check and the verdict no longer applies to it;
#'   * the record exists, matches, and records a failure.
#'
#' The middle case is the one a person would most easily miss, and is exactly
#' what a hash comparison catches and a human review does not.
#'
#' @param priors_path Path to the priors file in force.
#' @param record_path Path to the recorded check.
#' @return Invisibly TRUE, or an error.
assert_prior_predictive_passed <- function(
    priors_path = project_path("config", "priors.yml"),
    record_path = project_path("config", "prior_predictive_record.yml")) {

  record <- read_prior_predictive_record(record_path)

  if (is.null(record)) {
    stop("Refusing to analyse: no prior predictive check has been recorded.\n",
         "  The analysis plan requires the check to pass before the plan takes ",
         "effect.\n",
         "  Run: Rscript scripts/record_prior_predictive_check.R",
         call. = FALSE)
  }

  current_hash <- file_sha256(priors_path)
  if (!identical(record$priors_sha256, current_hash)) {
    stop("Refusing to analyse: the priors have changed since the prior ",
         "predictive check was recorded.\n",
         "  recorded against: ", substr(record$priors_sha256, 1, 16), "\n",
         "  priors now:       ", substr(current_hash, 1, 16), "\n",
         "  The recorded verdict does not apply to the priors in force. ",
         "Re-run the check.",
         call. = FALSE)
  }

  if (!identical(record$status, "pass")) {
    stop("Refusing to analyse: the recorded prior predictive check did not ",
         "pass.\n",
         "  priors version: ", record$priors_version, "\n",
         "  proportion of prior mass outside the outcome bounds: ",
         record$results$proportion_outside_outcome_bounds,
         " (limit ", record$criteria$max_proportion_outside_bounds, ")\n",
         "  proportion of prior-implied effects implausibly large: ",
         record$results$proportion_effect_implausibly_large,
         " (limit ", record$criteria$max_proportion_effect_implausible, ")\n",
         "  A prior that implies trials which could not happen is wrong. ",
         "Amend the plan and re-record the check before analysing.",
         call. = FALSE)
  }

  invisible(TRUE)
}
