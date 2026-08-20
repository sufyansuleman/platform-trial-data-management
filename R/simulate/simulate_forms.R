# ---------------------------------------------------------------------------
# The four remaining forms -- daily ICU records, 30-day outcomes and adverse
# events -- plus the data-entry timeliness model that stamps every record with
# the date it reached the EDC.
# ---------------------------------------------------------------------------

#' Simulate a single life-support trajectory
#'
#' Support on day 0 is a logistic function of severity. Each subsequent day the
#' underlying probability tapers, but support already in place tends to
#' continue: `persistence` is the probability of continuing given yesterday.
#' Without that term, independent daily draws give implausibly fragmented
#' on/off patterns that would distort the derived endpoint.
#'
#' @param days Integer vector of ICU day numbers, in order.
#' @param severity Baseline severity score.
#' @param spec Config block for this support type.
#' @return Integer vector of 0/1, one per element of `days`.
simulate_support_trajectory <- function(days, severity, spec) {
  base_p <- inv_logit(spec$intercept + spec$severity_coefficient * severity)
  on <- integer(length(days))
  previous <- 0L

  for (i in seq_along(days)) {
    p_today <- base_p * spec$daily_taper^days[i]
    if (previous == 1L) {
      p_today <- p_today + (1 - p_today) * spec$persistence
    }
    on[i] <- stats::rbinom(1, 1, min(1, p_today))
    previous <- on[i]
  }
  on
}

#' Simulate the daily ICU form
#'
#' One row per participant per ICU day. Rows exist only for days the
#' participant was physically in an ICU: a participant discharged alive on day
#' 10 has no rows for days 10 onward unless they are readmitted.
#'
#' Conventions, both recorded in docs/decisions.md:
#'   * `alive` is 1 on the day of death, since the participant was alive for
#'     part of that day. No rows exist after the day of death.
#'   * Absence of a row is NOT the same as absence of support. Interpreting
#'     absence is the ingest and derive layers' problem, not this function's.
#'
#' @param cfg Trial configuration.
#' @param course Clinical course from [simulate_clinical_course()].
#' @return A data frame conforming to `config/schema/daily_icu.yml` (without
#'   `entry_date`, which is added later).
simulate_daily_icu <- function(cfg, course) {
  clin <- cfg$clinical
  support_specs <- clin$life_support

  per_participant <- lapply(seq_len(nrow(course)), function(i) {
    p <- course[i, ]

    # ICU days: the index episode, plus a readmission episode if there was one.
    episode_days <- seq.int(0, p$icu_los - 1)
    if (!is.na(p$readmit_day)) {
      episode_days <- c(episode_days,
                        seq.int(p$readmit_day, p$readmit_day + p$readmit_los - 1))
    }
    # No records after the day of death.
    if (!is.na(p$death_day)) {
      episode_days <- episode_days[episode_days <= p$death_day]
    }
    episode_days <- episode_days[episode_days <= clin$max_follow_up_days]
    if (length(episode_days) == 0) return(NULL)

    n_days <- length(episode_days)

    # ICU unit; a transfer moves the participant to a second unit at this site.
    unit_number <- rep(1L, n_days)
    if (!is.na(p$transfer_day)) {
      unit_number[episode_days >= p$transfer_day] <- 2L
    }

    data.frame(
      participant_id          = p$participant_id,
      site_id                 = p$site_id,
      icu_day                 = as.integer(episode_days),
      record_date             = p$index_date + episode_days,
      alive                   = 1L,
      in_icu                  = 1L,
      mechanical_ventilation  = simulate_support_trajectory(
        episode_days, p$severity_score, support_specs$mechanical_ventilation),
      vasopressors            = simulate_support_trajectory(
        episode_days, p$severity_score, support_specs$vasopressors),
      renal_replacement       = simulate_support_trajectory(
        episode_days, p$severity_score, support_specs$renal_replacement),
      icu_location            = sprintf("%s-ICU%d", p$site_id, unit_number),
      heart_rate              = as.integer(round(rnorm_bounded(
        n_days, 88 + 0.45 * p$severity_score, 16, 35, 190))),
      temperature_c           = round(rnorm_bounded(n_days, 37.1, 0.9, 33, 41.5), 1),
      stringsAsFactors        = FALSE
    )
  })

  out <- do.call(rbind, per_participant)
  out$record_id <- sprintf("DLY-%07d", seq_len(nrow(out)))
  out[, c("record_id", "participant_id", "site_id", "icu_day", "record_date",
          "alive", "in_icu", "mechanical_ventilation", "vasopressors",
          "renal_replacement", "icu_location", "heart_rate", "temperature_c")]
}

#' Simulate the 30-day outcome form
#'
#' One row per participant per domain. Vital status is assessed 30 days after
#' *that domain's* randomisation, so a participant entered into two domains a
#' day apart has two windows that overlap but do not coincide.
#'
#' @param cfg Trial configuration.
#' @param course Clinical course.
#' @param randomisation Randomisation form.
#' @return A data frame conforming to `config/schema/outcome_30d.yml` (without
#'   `entry_date`).
simulate_outcome_30d <- function(cfg, course, randomisation) {
  window <- cfg$clinical$outcome_window_days

  lookup <- match(randomisation$participant_id, course$participant_id)
  index_date <- course$index_date[lookup]
  death_day <- course$death_day[lookup]
  icu_los <- course$icu_los[lookup]

  death_date <- as.Date(ifelse(is.na(death_day), NA, index_date + death_day),
                        origin = "1970-01-01")
  domain_rand_date <- as.Date(randomisation$randomisation_datetime)

  # Dead only if death falls within this domain's own 30-day window.
  dead_in_window <- !is.na(death_date) & death_date <= domain_rand_date + window
  vital_status <- ifelse(dead_in_window, "dead", "alive")

  # Survivors leave hospital some days after leaving the ICU.
  ward_days <- ceiling(stats::runif(nrow(randomisation), 0, 9))
  discharge_date <- as.Date(ifelse(dead_in_window, NA,
                                   index_date + icu_los + ward_days),
                            origin = "1970-01-01")

  data.frame(
    participant_id           = randomisation$participant_id,
    domain                   = randomisation$domain,
    site_id                  = randomisation$site_id,
    vital_status_30d         = vital_status,
    death_date               = as.Date(ifelse(dead_in_window, death_date, NA),
                                       origin = "1970-01-01"),
    icu_admission_date       = index_date,
    hospital_discharge_date  = discharge_date,
    stringsAsFactors         = FALSE
  )
}

#' Simulate the adverse event form
#'
#' Adverse events arise at a low rate per participant per ICU day, so sicker
#' participants with longer stays accumulate more of them. Seriousness and
#' relatedness are drawn independently of the event code.
#'
#' @param cfg Trial configuration.
#' @param course Clinical course.
#' @param daily_icu Daily ICU form, used to place events on days actually spent
#'   in the ICU.
#' @return A data frame conforming to `config/schema/adverse_events.yml`
#'   (without `entry_date`).
simulate_adverse_events <- function(cfg, course, daily_icu) {
  spec <- cfg$clinical$adverse_events

  n_rows <- nrow(daily_icu)
  has_event <- stats::rbinom(n_rows, 1, spec$daily_rate) == 1
  event_rows <- daily_icu[has_event, ]
  if (nrow(event_rows) == 0) {
    stop("No adverse events generated; check clinical$adverse_events$daily_rate.")
  }

  n <- nrow(event_rows)
  data.frame(
    ae_id           = sprintf("AE-%06d", seq_len(n)),
    participant_id  = event_rows$participant_id,
    site_id         = event_rows$site_id,
    ae_code         = sample(unlist(spec$codes), n, replace = TRUE),
    onset_date      = event_rows$record_date,
    serious         = stats::rbinom(n, 1, spec$serious_fraction),
    related         = stats::rbinom(n, 2, spec$related_fraction),
    stringsAsFactors = FALSE
  )
}

#' Stamp records with the date they reached the EDC
#'
#' Entry delay is drawn from a log-normal centred on the configured median, and
#' lengthened when the event falls near a public holiday in the site's own
#' country. This is why timeliness must be read against a country calendar: a
#' Danish site in late December and a Dutch site in the same week are not
#' comparable on a single global scale.
#'
#' Assumes every `site_id` present in `data` exists in `sites`.
#'
#' @param data A form to stamp.
#' @param event_col Name of the column holding the clinical event date.
#' @param cfg Trial configuration.
#' @param sites Resolved site table.
#' @param calendar Holiday calendar from [holiday_calendar()].
#' @return `data` with an `entry_date` column appended.
add_entry_dates <- function(data, event_col, cfg, sites, calendar) {
  spec <- cfg$timeliness
  event_date <- as.Date(data[[event_col]])
  n <- nrow(data)

  # Log-normal delay: right-skewed, always positive, median as configured.
  sdlog <- sqrt(log(1 + (spec$baseline_sd_days / spec$baseline_median_days)^2))
  delay <- stats::rlnorm(n, log(spec$baseline_median_days), sdlog)

  country <- sites$country[match(data$site_id, sites$site_id)]
  for (cc in unique(country)) {
    rows <- which(country == cc)
    near <- near_holiday(event_date[rows], cc, calendar, spec$holiday_window_days)
    delay[rows][near] <- delay[rows][near] + spec$holiday_entry_delay_days
  }

  data$entry_date <- event_date + pmin(spec$max_delay_days, ceiling(delay))
  data
}
