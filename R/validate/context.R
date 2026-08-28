# ---------------------------------------------------------------------------
# Rule context.
#
# The rule engine evaluates each rule's `expression` against one form. Many
# useful checks need a fact that lives on a different form -- when the
# participant was randomised, whether they died, how many sites issued their
# identifier. Rather than give rule authors a join language to learn, those
# facts are computed here and attached to the form as ordinary columns.
#
# The effect is that a rule expression stays something a trial manager can read
# without knowing R:
#
#     onset_date >= first_randomisation_date
#
# Adding a new context column here is how the vocabulary available to rule
# authors grows. Every column added is documented in docs/validation_plan.md.
# ---------------------------------------------------------------------------

#' The clinical event date for each form
#'
#' Used by TMP-003, which checks that no record was entered before the event it
#' describes. Each form anchors on a different date.
#'
#' @param form Form name.
#' @return The column name holding that form's event date.
event_date_column <- function(form) {
  switch(
    form,
    screening      = "screening_date",
    randomisation  = "randomisation_datetime",
    daily_icu      = "record_date",
    outcome_30d    = "icu_admission_date",
    adverse_events = "onset_date",
    stop("No event date defined for form '", form, "'.", call. = FALSE)
  )
}

#' Attach derived context columns to every form
#'
#' Assumes the forms have already passed through ingest, so types are correct
#' and local conventions have been normalised.
#'
#' @param forms Named list of conformed forms.
#' @return The same list, each form carrying its context columns.
build_rule_context <- function(forms) {
  randomisation <- forms$randomisation
  outcome <- forms$outcome_30d

  # -- Participant-level facts, computed once and reused --------------------
  first_randomisation <- randomisation |>
    dplyr::group_by(participant_id) |>
    dplyr::summarise(
      first_randomisation_date = as.Date(min_or_na(randomisation_datetime)),
      .groups = "drop"
    )

  randomised_ids <- unique(randomisation$participant_id)

  # A participant's date of death, taken from whichever domain recorded one.
  # Disagreement between domains is itself a finding (XDM-001), so this takes
  # the earliest and lets that rule report the inconsistency separately.
  death_dates <- outcome |>
    dplyr::group_by(participant_id) |>
    dplyr::summarise(death_date_participant = min_or_na(death_date),
                     .groups = "drop")

  screening_dates <- forms$screening |>
    dplyr::filter(!is.na(participant_id)) |>
    dplyr::group_by(participant_id) |>
    dplyr::summarise(screening_date_for_participant = min_or_na(screening_date),
                     .groups = "drop")

  # -- screening ------------------------------------------------------------
  forms$screening <- forms$screening |>
    dplyr::group_by(participant_id) |>
    dplyr::mutate(
      sites_using_participant_id = ifelse(is.na(participant_id), 1L,
                                          dplyr::n_distinct(site_id))
    ) |>
    dplyr::ungroup()

  # -- randomisation --------------------------------------------------------
  forms$randomisation <- forms$randomisation |>
    dplyr::group_by(participant_id, domain) |>
    dplyr::mutate(randomisations_in_domain = dplyr::n()) |>
    dplyr::ungroup() |>
    dplyr::left_join(screening_dates, by = "participant_id")

  # -- daily_icu ------------------------------------------------------------
  # `days_since_previous_record` is 1 for a normal consecutive day. A larger
  # value means days are missing between two recorded days. The first record
  # of a stay has no predecessor and is given 1 so it never trips the rule.
  forms$daily_icu <- forms$daily_icu |>
    dplyr::arrange(participant_id, icu_day) |>
    dplyr::group_by(participant_id) |>
    dplyr::mutate(
      days_since_previous_record = ifelse(dplyr::row_number() == 1, 1L,
                                          icu_day - dplyr::lag(icu_day))
    ) |>
    dplyr::ungroup() |>
    dplyr::left_join(death_dates, by = "participant_id") |>
    dplyr::mutate(
      participant_is_randomised = participant_id %in% randomised_ids,
      # A participant with no recorded death has no date to violate, so the
      # comparison is made against a date that nothing can exceed.
      death_date_or_infinity = dplyr::coalesce(death_date_participant,
                                               as.Date("9999-12-31"))
    )

  # -- outcome_30d ----------------------------------------------------------
  # The 30-day window is anchored to THIS domain's randomisation, not the
  # participant's first. Two domains entered a day apart have windows that
  # overlap but end on different days, and that difference is legitimate.
  domain_randomisation <- randomisation |>
    dplyr::group_by(participant_id, domain) |>
    dplyr::summarise(domain_randomisation_date = as.Date(min_or_na(randomisation_datetime)),
                     .groups = "drop")

  forms$outcome_30d <- forms$outcome_30d |>
    dplyr::left_join(first_randomisation, by = "participant_id") |>
    dplyr::left_join(domain_randomisation, by = c("participant_id", "domain")) |>
    dplyr::mutate(
      participant_is_randomised = participant_id %in% randomised_ids,
      window_end_date = domain_randomisation_date + 30,
      death_date_and_status_agree =
        (vital_status_30d == "dead" & !is.na(death_date)) |
        (vital_status_30d != "dead" & is.na(death_date))
    ) |>
    dplyr::group_by(participant_id) |>
    dplyr::mutate(
      distinct_death_dates_for_participant =
        dplyr::n_distinct(death_date[!is.na(death_date)]),
      distinct_admission_dates_for_participant =
        dplyr::n_distinct(icu_admission_date[!is.na(icu_admission_date)])
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(participant_id, window_end_date) |>
    dplyr::mutate(
      vital_status_consistent_at_shared_window =
        dplyr::n_distinct(vital_status_30d) <= 1
    ) |>
    dplyr::ungroup()

  # -- adverse_events -------------------------------------------------------
  forms$adverse_events <- forms$adverse_events |>
    dplyr::left_join(first_randomisation, by = "participant_id") |>
    dplyr::mutate(participant_is_randomised = participant_id %in% randomised_ids)

  # -- shared: entry cannot precede the event -------------------------------
  for (form in names(forms)) {
    event_column <- event_date_column(form)
    event_date <- as.Date(forms[[form]][[event_column]])
    forms[[form]]$entry_not_before_event <-
      is.na(event_date) | is.na(forms[[form]]$entry_date) |
      forms[[form]]$entry_date >= event_date
  }

  forms
}
