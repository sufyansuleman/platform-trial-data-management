# ---------------------------------------------------------------------------
# Days alive without life support at 30 days.
#
# This is the primary endpoint. It is the number an adaptive stopping decision
# reads, which is why it has more tests than anything else in this repository
# and why every convention below is stated explicitly rather than left to the
# reader to infer from the code.
#
# THE CONVENTIONS, all recorded in docs/decisions.md:
#
#   1. WINDOW. Days 0 to 29 inclusive, where day 0 is the day of randomisation
#      into THIS domain. Thirty days. A participant in two domains randomised
#      two days apart has two different windows, and each is scored against its
#      own anchor.
#
#   2. DEATH. Death on or before day 30 scores 0, whatever happened before it.
#      Day 30 counts as inside; day 31 does not. Both readings of "within 30
#      days" are defensible and they disagree about exactly one day, so the
#      boundary is pinned here and tested.
#
#   3. PARTIAL DAYS. The daily record carries a day-level flag: it says support
#      was given at some point that day, not for how long. Any support on a day
#      disqualifies the whole day. Counting fractions would invent precision
#      the data does not carry.
#
#   4. MISSING RECORDS. This is the consequential one. A day with no record is
#      UNKNOWN, not free of support -- UNLESS a documented discharge alive
#      explains the absence, in which case the day is free. Crediting
#      unexplained gaps would inflate the endpoint in proportion to how badly a
#      site enters its data, turning a data-quality problem into an apparent
#      treatment effect.
#
#   5. CONFLICTS. Two records for the same day that disagree make the day
#      unknown. Silently preferring one would hide a data problem behind a
#      confident-looking integer.
#
# The function therefore returns the count alongside `unknown_days` and
# `complete`. An analyst must be able to see how much of the estimate rests on
# absent data instead of being handed a single number that looks certain.
# ---------------------------------------------------------------------------

#' Derive days alive without life support at 30 days
#'
#' One row per participant per domain, since each domain's window is anchored
#' to its own randomisation.
#'
#' Assumes the forms have passed through ingest, so dates are real dates and
#' the support flags are 0, 1 or NA. NA in any support flag makes the day
#' unknown: a blank is not a zero.
#'
#' @param daily_icu Daily ICU records.
#' @param outcome_30d 30-day outcome records, one per participant per domain.
#' @param randomisation Randomisation records, used to anchor each window.
#' @param window_days Length of the window in days.
#' @return A data frame with `participant_id`, `domain`,
#'   `days_alive_without_life_support`, `unknown_days`, `conflicting_days`,
#'   `died_within_window` and `complete`.
derive_days_alive_without_life_support <- function(daily_icu, outcome_30d,
                                                   randomisation,
                                                   window_days = 30) {
  if (!nrow(outcome_30d)) return(empty_dawols())

  anchors <- randomisation |>
    dplyr::group_by(participant_id, domain) |>
    dplyr::summarise(anchor_date = as.Date(min_or_na(randomisation_datetime)),
                     .groups = "drop")

  subjects <- outcome_30d |>
    dplyr::select(participant_id, domain, site_id, death_date,
                  hospital_discharge_date) |>
    dplyr::left_join(anchors, by = c("participant_id", "domain")) |>
    dplyr::mutate(
      subject_row = dplyr::row_number(),
      # Death on or before day `window_days` zeroes the endpoint.
      died_within_window = !is.na(death_date) & !is.na(anchor_date) &
        death_date <= anchor_date + window_days
    )

  # -- One row per subject per day of their window --------------------------
  window <- subjects |>
    dplyr::filter(!is.na(anchor_date)) |>
    dplyr::select(subject_row, participant_id, anchor_date,
                  hospital_discharge_date) |>
    tidyr::expand_grid(day_offset = seq.int(0, window_days - 1)) |>
    dplyr::mutate(window_date = anchor_date + day_offset)

  # -- Collapse the daily records to one status per participant per day -----
  # The last day the participant was seen in an ICU. A missing day after this
  # is a day they had left the ICU; a missing day before it falls inside the
  # recorded stay and is genuinely unknown.
  last_icu_record <- daily_icu |>
    dplyr::group_by(participant_id) |>
    dplyr::summarise(last_icu_record_date = max(as.Date(record_date), na.rm = TRUE),
                     .groups = "drop")

  # Agreement is judged on the fields the endpoint actually reads. Two records
  # for a transfer day that name different ICU units but the same support are
  # not in conflict about anything that matters here.
  daily_status <- daily_icu |>
    dplyr::mutate(
      record_date = as.Date(record_date),
      day_known = !is.na(alive) & !is.na(mechanical_ventilation) &
        !is.na(vasopressors) & !is.na(renal_replacement),
      day_free = day_known & alive == 1 & mechanical_ventilation == 0 &
        vasopressors == 0 & renal_replacement == 0,
      status_key = paste(alive, mechanical_ventilation, vasopressors,
                         renal_replacement)
    ) |>
    dplyr::group_by(participant_id, record_date) |>
    dplyr::summarise(
      records = dplyr::n(),
      conflicting = dplyr::n_distinct(status_key) > 1,
      day_known = all(day_known),
      day_free = all(day_free),
      .groups = "drop"
    )

  # -- Classify every day in every window -----------------------------------
  classified <- window |>
    dplyr::left_join(daily_status,
                     by = c("participant_id", "window_date" = "record_date")) |>
    dplyr::left_join(last_icu_record, by = "participant_id") |>
    dplyr::mutate(
      has_record = !is.na(records),
      # A missing day is explained -- alive and free of life support -- when
      # positive evidence places the participant outside an ICU on that day.
      # There are two independent sources of that evidence, and BOTH are
      # needed:
      #
      #   * The day falls after the last ICU record. Life support is given in
      #     an ICU, so a participant who has left one is not receiving it.
      #     This covers the ward days between ICU discharge and hospital
      #     discharge, which are the majority of explained days and which an
      #     earlier version of this function wrongly counted as unknown.
      #
      #   * The day falls after a documented hospital discharge. This covers
      #     the days between an ICU discharge and a later readmission, where
      #     the participant is back in an ICU afterwards so the first test
      #     does not apply.
      #
      # A missing day that neither explains is interior to the recorded stay
      # and stays unknown. See DEC-006.
      after_last_icu_record = !is.na(last_icu_record_date) &
        window_date > last_icu_record_date,
      after_hospital_discharge = !is.na(hospital_discharge_date) &
        window_date > hospital_discharge_date,
      explained_by_discharge = !has_record &
        (after_last_icu_record | after_hospital_discharge),
      day_conflicting = has_record & conflicting,
      day_unknown = (!has_record & !explained_by_discharge) |
        (has_record & (!day_known | conflicting)),
      day_counts = dplyr::case_when(
        day_conflicting          ~ FALSE,
        has_record               ~ day_known & day_free,
        explained_by_discharge   ~ TRUE,
        TRUE                     ~ FALSE
      )
    )

  scored <- classified |>
    dplyr::group_by(subject_row) |>
    dplyr::summarise(
      free_days = sum(day_counts),
      unknown_days = sum(day_unknown),
      conflicting_days = sum(day_conflicting),
      .groups = "drop"
    )

  out <- subjects |>
    dplyr::left_join(scored, by = "subject_row") |>
    dplyr::mutate(
      # Death makes the endpoint 0 by definition, so nothing about the daily
      # records can change it and there is no missing information left to
      # report: the value is complete even if days are unrecorded.
      days_alive_without_life_support = dplyr::case_when(
        is.na(anchor_date)  ~ NA_integer_,
        died_within_window  ~ 0L,
        TRUE                ~ as.integer(free_days)
      ),
      unknown_days = dplyr::case_when(
        is.na(anchor_date) ~ NA_integer_,
        died_within_window ~ 0L,
        TRUE               ~ as.integer(unknown_days)
      ),
      conflicting_days = dplyr::coalesce(as.integer(conflicting_days), 0L),
      # A record whose endpoint could not be computed at all -- no
      # randomisation date to anchor the window -- is definitively NOT
      # complete. Leaving `complete` as NA there propagates into every count
      # downstream and silently turns totals into NA or zero.
      complete = !is.na(days_alive_without_life_support) &
        !is.na(unknown_days) & unknown_days == 0
    )

  out[, c("participant_id", "domain", "site_id",
          "days_alive_without_life_support", "unknown_days",
          "conflicting_days", "died_within_window", "complete")] |>
    as.data.frame()
}

#' An empty endpoint table with the correct columns
#'
#' @return A zero-row data frame.
empty_dawols <- function() {
  data.frame(
    participant_id = character(), domain = character(), site_id = character(),
    days_alive_without_life_support = integer(), unknown_days = integer(),
    conflicting_days = integer(), died_within_window = logical(),
    complete = logical(), stringsAsFactors = FALSE
  )
}

#' Summarise the endpoint for reporting
#'
#' Reports the completeness of the endpoint alongside its distribution,
#' because a mean computed over participants with unknown days is a different
#' quantity from one computed over complete records, and the difference is
#' exactly what a monitoring report should surface.
#'
#' @param endpoint Output of [derive_days_alive_without_life_support()].
#' @param by Optional grouping column name.
#' @return A data frame summary.
summarise_dawols <- function(endpoint, by = NULL) {
  grouped <- if (is.null(by)) endpoint else dplyr::group_by(endpoint, .data[[by]])
  grouped |>
    dplyr::summarise(
      n = dplyr::n(),
      # Output names differ from the `complete` column deliberately:
      # summarise() evaluates in order, so a result named `complete` would
      # shadow the column for every expression after it.
      not_evaluable = sum(is.na(days_alive_without_life_support)),
      n_complete = sum(complete),
      n_incomplete = sum(!complete & !is.na(days_alive_without_life_support)),
      died_within_window = sum(died_within_window, na.rm = TRUE),
      mean_all = round(mean(days_alive_without_life_support, na.rm = TRUE), 2),
      mean_complete_only = round(
        mean(days_alive_without_life_support[which(complete)], na.rm = TRUE), 2),
      median_all = stats::median(days_alive_without_life_support, na.rm = TRUE),
      total_unknown_days = sum(unknown_days, na.rm = TRUE),
      .groups = "drop"
    ) |>
    as.data.frame()
}
