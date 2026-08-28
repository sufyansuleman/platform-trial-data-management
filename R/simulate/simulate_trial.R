# ---------------------------------------------------------------------------
# Orchestrator: turn config/trial.yml into a complete, clean set of five
# forms. Defect injection happens afterwards, in inject_defects.R, so that the
# clean dataset is always available as a reference.
# ---------------------------------------------------------------------------

#' Generate the complete clean trial dataset
#'
#' Runs the whole simulation from the seed in config. Determinism is the
#' contract here: the same config in must produce byte-identical data out, so
#' the seed is set once at the top and every downstream draw follows from it.
#'
#' Assumes `config/trial.yml` and `config/schema/*.yml` are consistent with one
#' another; a column generated here but missing from the schema will be caught
#' by the ingest conformance check, not by this function.
#'
#' @param cfg Trial configuration. Loaded from disk if not supplied.
#' @return A named list of five data frames, one per form, each carrying an
#'   `entry_date`. Also returns `course`, the latent clinical truth, which is
#'   used by defect injection but never exported to the EDC.
simulate_trial <- function(cfg = load_trial_config()) {
  set.seed(cfg$trial$seed)

  sites <- resolve_sites(cfg)
  calendar <- holiday_calendar(cfg)

  screening <- simulate_screening(cfg, sites)
  randomisation <- simulate_randomisation(cfg, screening)
  course <- simulate_clinical_course(cfg, screening, randomisation)
  daily_icu <- simulate_daily_icu(cfg, course)
  outcome_30d <- simulate_outcome_30d(cfg, course, randomisation)
  adverse_events <- simulate_adverse_events(cfg, course, daily_icu)

  # Every form carries the date it reached the EDC, which is what the
  # timeliness metrics in the monitoring reports are computed from.
  screening <- add_entry_dates(screening, "screening_date", cfg, sites, calendar)
  randomisation <- add_entry_dates(randomisation, "randomisation_datetime", cfg, sites, calendar)
  daily_icu <- add_entry_dates(daily_icu, "record_date", cfg, sites, calendar)
  outcome_30d <- add_entry_dates(outcome_30d, "icu_admission_date", cfg, sites, calendar)
  adverse_events <- add_entry_dates(adverse_events, "onset_date", cfg, sites, calendar)

  list(
    screening      = screening,
    randomisation  = randomisation,
    daily_icu      = daily_icu,
    outcome_30d    = outcome_30d,
    adverse_events = adverse_events,
    course         = course
  )
}

#' Row counts for a set of forms
#'
#' A small reporting helper used at checkpoints and in the pipeline log.
#'
#' @param forms Named list of data frames.
#' @return A data frame with `form`, `rows` and `columns`.
form_row_counts <- function(forms) {
  named <- forms[setdiff(names(forms), "course")]
  data.frame(
    form    = names(named),
    rows    = vapply(named, nrow, integer(1)),
    columns = vapply(named, ncol, integer(1)),
    row.names = NULL,
    stringsAsFactors = FALSE
  )
}
