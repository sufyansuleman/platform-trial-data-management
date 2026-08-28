# ---------------------------------------------------------------------------
# Fixtures for the derived endpoint.
#
# The endpoint is the number every adaptive stopping decision reads, so its
# tests are built to be readable at a glance: each one states a participant's
# course in a single line and asserts one number.
# ---------------------------------------------------------------------------

DERIVE_ANCHOR <- as.Date("2025-01-06")   # day 0 for every fixture participant

#' Build a daily ICU record set for one participant
#'
#' @param days Integer vector of day offsets from randomisation.
#' @param mv,vp,rrt Support flags, recycled to the length of `days`.
#' @param alive Alive flag, recycled.
#' @param participant_id,site_id Identifiers.
#' @param location ICU unit, recycled; use to model a transfer.
#' @param anchor Day-zero date.
#' @return A data frame shaped like the daily_icu form.
daily_records <- function(days, mv = 0, vp = 0, rrt = 0, alive = 1,
                          participant_id = "P-000001", site_id = "DK-01",
                          location = "DK-01-ICU1", anchor = DERIVE_ANCHOR) {
  n <- length(days)
  data.frame(
    record_id = sprintf("DLY-%07d", seq_len(n)),
    participant_id = participant_id,
    site_id = site_id,
    icu_day = as.integer(days),
    record_date = anchor + days,
    alive = rep_len(as.integer(alive), n),
    in_icu = 1L,
    mechanical_ventilation = rep_len(as.integer(mv), n),
    vasopressors = rep_len(as.integer(vp), n),
    renal_replacement = rep_len(as.integer(rrt), n),
    icu_location = rep_len(location, n),
    heart_rate = 85L,
    temperature_c = 37,
    entry_date = anchor + days + 1,
    stringsAsFactors = FALSE
  )
}

#' Build a one-row outcome record
#'
#' @param death_day Day offset of death, or NA if alive at 30 days.
#' @param discharge_day Day offset of hospital discharge, or NA.
#' @param participant_id,domain,site_id Identifiers.
#' @param anchor Day-zero date.
#' @return A data frame shaped like the outcome_30d form.
outcome_record <- function(death_day = NA, discharge_day = NA,
                           participant_id = "P-000001", domain = "FLUID",
                           site_id = "DK-01", anchor = DERIVE_ANCHOR) {
  data.frame(
    participant_id = participant_id,
    domain = domain,
    site_id = site_id,
    vital_status_30d = if (!is.na(death_day) && death_day <= 30) "dead" else "alive",
    death_date = if (is.na(death_day)) as.Date(NA) else anchor + death_day,
    icu_admission_date = anchor,
    hospital_discharge_date = if (is.na(discharge_day)) as.Date(NA) else anchor + discharge_day,
    entry_date = anchor + 31,
    stringsAsFactors = FALSE
  )
}

#' Build a one-row randomisation record
#'
#' @param day_offset Days after the anchor that this domain randomised.
#' @param participant_id,domain,site_id Identifiers.
#' @param anchor Day-zero date.
#' @return A data frame shaped like the randomisation form.
randomisation_record <- function(day_offset = 0, participant_id = "P-000001",
                                 domain = "FLUID", site_id = "DK-01",
                                 anchor = DERIVE_ANCHOR) {
  data.frame(
    randomisation_id = sprintf("RND-%s", substr(domain, 1, 3)),
    participant_id = participant_id,
    site_id = site_id,
    domain = domain,
    arm = "restrictive",
    randomisation_datetime = as.POSIXct(paste(anchor + day_offset, "10:00:00"),
                                        tz = "UTC"),
    allocation_ratio = "1:1",
    entry_date = anchor + day_offset + 1,
    stringsAsFactors = FALSE
  )
}

#' Compute the endpoint for a single simple case
#'
#' Wraps the vectorised function so a test can read as one assertion.
#'
#' @param daily,outcome,randomisation Fixture forms.
#' @return The one-row result.
dawols_for <- function(daily, outcome = outcome_record(),
                       randomisation = randomisation_record()) {
  result <- derive_days_alive_without_life_support(daily, outcome, randomisation)
  expect_equal(nrow(result), 1)
  result
}
