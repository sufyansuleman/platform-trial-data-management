# ---------------------------------------------------------------------------
# Enrolment timing, screening, randomisation and the underlying clinical
# course. Everything here is driven by config/trial.yml -- no literal
# parameters.
# ---------------------------------------------------------------------------

#' Build the monthly enrolment weight matrix
#'
#' Enrolment volume at a site in a month is the product of its capacity, how
#' much of the month it had been initiated for, how far it is through its own
#' ramp-up, and the calendar seasonality of that month.
#'
#' Assumes site initiation dates fall on or before the end of the enrolment
#' window; sites initiated later simply contribute zero weight throughout.
#'
#' @param cfg Trial configuration.
#' @param sites Resolved site table from [resolve_sites()].
#' @return A matrix of enrolment weights, sites in rows, months in columns.
enrolment_weights <- function(cfg, sites) {
  start <- as.Date(cfg$enrolment$start_date)
  n_months <- cfg$enrolment$months
  month_starts <- seq(start, by = "month", length.out = n_months)
  month_ends <- c(month_starts[-1], seq(month_starts[n_months], by = "month", length.out = 2)[2])

  ramp_floor <- cfg$enrolment$ramp_floor
  ramp_months <- cfg$enrolment$ramp_up_months

  weights <- matrix(0, nrow = nrow(sites), ncol = n_months,
                    dimnames = list(sites$site_id, format(month_starts, "%Y-%m")))

  for (i in seq_len(nrow(sites))) {
    for (m in seq_len(n_months)) {
      days_in_month <- as.numeric(month_ends[m] - month_starts[m])
      active_from <- max(month_starts[m], sites$initiation_date[i])
      active_days <- as.numeric(month_ends[m] - active_from)
      if (active_days <= 0) next

      # Ramp is measured from the site's own initiation, so a site opening in
      # month 20 still starts slowly rather than inheriting the trial's ramp.
      months_open <- as.numeric(month_starts[m] - sites$initiation_date[i]) / 30.44
      ramp <- ramp_floor + (1 - ramp_floor) * min(1, max(0, months_open) / ramp_months)

      seasonal <- cfg$enrolment$seasonal_multipliers[[
        as.character(as.integer(format(month_starts[m], "%m")))
      ]]

      weights[i, m] <- sites$capacity[i] * (active_days / days_in_month) *
        ramp * seasonal
    }
  }
  weights
}

#' Allocate screening events across sites and months
#'
#' Converts the enrolment weight matrix into an integer count of screened
#' patients per site-month, scaled so the expected number of *randomised*
#' participants matches the configured target.
#'
#' @param cfg Trial configuration.
#' @param sites Resolved site table.
#' @return A data frame with `site_id`, `month_start` and `n_screened`.
allocate_screening <- function(cfg, sites) {
  weights <- enrolment_weights(cfg, sites)
  target_screened <- cfg$enrolment$target_participants / cfg$enrolment$enrolled_fraction
  expected <- weights / sum(weights) * target_screened

  month_starts <- seq(as.Date(cfg$enrolment$start_date), by = "month",
                      length.out = cfg$enrolment$months)

  counts <- matrix(stats::rpois(length(expected), expected),
                   nrow = nrow(expected), dimnames = dimnames(expected))

  out <- expand.grid(site_id = sites$site_id, month_index = seq_along(month_starts),
                     stringsAsFactors = FALSE)
  out$month_start <- month_starts[out$month_index]
  out$n_screened <- as.vector(counts)
  out[out$n_screened > 0, c("site_id", "month_start", "n_screened"), drop = FALSE]
}

#' Simulate the screening form
#'
#' Generates one row per screened patient with baseline characteristics and
#' eligibility flags. A patient is enrolled only if all three eligibility
#' criteria are met; the criteria probabilities are calibrated so that the
#' overall enrolled fraction matches `enrolment$enrolled_fraction`.
#'
#' @param cfg Trial configuration.
#' @param sites Resolved site table.
#' @return A data frame conforming to `config/schema/screening.yml`, plus the
#'   internal columns `severity_score` and `country` used downstream.
simulate_screening <- function(cfg, sites) {
  allocation <- allocate_screening(cfg, sites)
  n <- sum(allocation$n_screened)

  # Spread each site-month's screenings uniformly across that month.
  site_id <- rep(allocation$site_id, allocation$n_screened)
  month_start <- rep(allocation$month_start, allocation$n_screened)
  day_offset <- floor(stats::runif(n, 0, 30))
  screening_date <- month_start + day_offset

  ord <- order(screening_date, site_id)
  site_id <- site_id[ord]
  screening_date <- screening_date[ord]

  clin <- cfg$clinical
  # Each eligibility criterion is met with probability p, and all three must
  # hold, so p is the cube root of the target enrolled fraction.
  p_criterion <- cfg$enrolment$enrolled_fraction^(1 / 3)

  elig_icu <- stats::rbinom(n, 1, p_criterion)
  elig_consent <- stats::rbinom(n, 1, p_criterion)
  elig_no_exclusion <- stats::rbinom(n, 1, p_criterion)
  enrolled <- as.integer(elig_icu & elig_consent & elig_no_exclusion)

  screening <- data.frame(
    screening_id      = sprintf("SCR-%06d", seq_len(n)),
    participant_id    = NA_character_,
    site_id           = site_id,
    screening_date    = screening_date,
    age_years         = as.integer(round(rnorm_bounded(n, clin$age$mean, clin$age$sd,
                                                       clin$age$min, clin$age$max))),
    sex               = ifelse(stats::rbinom(n, 1, clin$female_fraction) == 1, "F", "M"),
    weight_kg         = round(rnorm_bounded(n, clin$weight_kg$mean, clin$weight_kg$sd,
                                            clin$weight_kg$min, clin$weight_kg$max), 1),
    creatinine        = round(rnorm_bounded(n, 110, 55, 20, 900), 0),
    severity_score    = as.integer(round(rnorm_bounded(n, clin$severity$mean, clin$severity$sd,
                                                       clin$severity$min, clin$severity$max))),
    elig_icu          = elig_icu,
    elig_consent      = elig_consent,
    elig_no_exclusion = elig_no_exclusion,
    enrolled          = enrolled,
    stringsAsFactors  = FALSE
  )

  # Participant IDs are issued in screening-date order, as they would be by a
  # central randomisation system.
  enrolled_rows <- which(screening$enrolled == 1)
  screening$participant_id[enrolled_rows] <-
    sprintf("P-%06d", seq_along(enrolled_rows))

  screening
}

#' Assign participants to platform domains
#'
#' Every randomised participant enters at least one domain. The number of
#' additional domains is drawn so that the mean number of randomisations per
#' participant matches the configured target, and which domains are entered is
#' weighted by each domain's eligibility fraction.
#'
#' Assumes the target is between 1 and the number of domains.
#'
#' @param cfg Trial configuration.
#' @param participant_ids Character vector of participant identifiers.
#' @return A data frame with `participant_id` and `domain`, one row per
#'   participant-domain.
assign_domains <- function(cfg, participant_ids) {
  domain_ids <- vapply(cfg$domains, function(d) d$id, character(1))
  domain_weight <- vapply(cfg$domains, function(d) d$eligibility_fraction, numeric(1))

  target <- cfg$multi_domain$target_randomisations_per_participant
  n_extra_possible <- length(domain_ids) - 1
  p_extra <- (target - 1) / n_extra_possible

  n_participants <- length(participant_ids)
  n_domains <- 1L + stats::rbinom(n_participants, n_extra_possible, p_extra)

  rows <- lapply(seq_len(n_participants), function(i) {
    chosen <- sample(domain_ids, size = n_domains[i], replace = FALSE,
                     prob = domain_weight)
    data.frame(participant_id = participant_ids[i], domain = chosen,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

#' Simulate the randomisation form
#'
#' Randomisation happens on the screening date or the day after. Allocation is
#' equal across arms within a domain, using the ratio recorded in config.
#'
#' @param cfg Trial configuration.
#' @param screening Screening form from [simulate_screening()].
#' @return A data frame conforming to `config/schema/randomisation.yml`.
simulate_randomisation <- function(cfg, screening) {
  enrolled <- screening[screening$enrolled == 1, ]
  pairs <- assign_domains(cfg, enrolled$participant_id)

  lookup <- match(pairs$participant_id, enrolled$participant_id)
  pairs$site_id <- enrolled$site_id[lookup]
  pairs$screening_date <- enrolled$screening_date[lookup]

  n <- nrow(pairs)
  domain_index <- match(pairs$domain, vapply(cfg$domains, function(d) d$id, character(1)))

  arm <- vapply(seq_len(n), function(i) {
    spec <- cfg$domains[[domain_index[i]]]
    sample(unlist(spec$arms), 1, prob = unlist(spec$allocation_ratio))
  }, character(1))

  ratio <- vapply(domain_index, function(k) {
    paste(unlist(cfg$domains[[k]]$allocation_ratio), collapse = ":")
  }, character(1))

  # Randomisation occurs the same day as screening or the following day, at a
  # plausible hour of the day.
  offset_days <- stats::rbinom(n, 1, 0.35)
  seconds_into_day <- floor(stats::runif(n, 6 * 3600, 23 * 3600))
  rand_time <- as.POSIXct(pairs$screening_date + offset_days, tz = "UTC") + seconds_into_day

  out <- data.frame(
    randomisation_id       = sprintf("RND-%06d", seq_len(n)),
    participant_id         = pairs$participant_id,
    site_id                = pairs$site_id,
    domain                 = pairs$domain,
    arm                    = arm,
    randomisation_datetime = rand_time,
    allocation_ratio       = ratio,
    stringsAsFactors       = FALSE
  )
  out[order(out$randomisation_datetime, out$participant_id), ]
}

#' Simulate each participant's underlying clinical course
#'
#' Produces the latent truth from which the daily, outcome and adverse event
#' forms are derived: severity, length of ICU stay, whether and when the
#' participant died, and whether they were transferred or readmitted.
#'
#' Assumes severity is fixed at baseline and drives everything downstream,
#' which is a simplification -- real severity evolves -- but it gives the
#' correlated structure the monitoring signals need.
#'
#' @param cfg Trial configuration.
#' @param screening Screening form.
#' @param randomisation Randomisation form.
#' @return A data frame, one row per participant, describing the course.
simulate_clinical_course <- function(cfg, screening, randomisation) {
  enrolled <- screening[screening$enrolled == 1, ]
  n <- nrow(enrolled)
  clin <- cfg$clinical

  # First randomisation anchors the participant's timeline. A participant in
  # several domains has several randomisation dates; day 0 is the earliest.
  first_rand <- stats::aggregate(randomisation_datetime ~ participant_id,
                                 data = randomisation, FUN = min)
  lookup <- match(enrolled$participant_id, first_rand$participant_id)
  index_datetime <- first_rand$randomisation_datetime[lookup]
  index_date <- as.Date(index_datetime)

  severity <- enrolled$severity_score
  centred <- severity - clin$mortality$severity_centre

  p_death <- inv_logit(clin$mortality$intercept +
                         clin$mortality$severity_coefficient * centred)
  died_by_30 <- stats::rbinom(n, 1, p_death) == 1

  # Deaths cluster early in the window. Draw from a truncated exponential so
  # the mean matches config, then clamp into 0..outcome_window_days.
  raw_death_day <- stats::rexp(n, rate = 1 / clin$mortality$mean_days_to_death)
  death_day <- ifelse(died_by_30,
                      pmin(clin$outcome_window_days, floor(raw_death_day)),
                      NA_real_)

  # ICU length of stay. Those who die leave the ICU by dying.
  raw_los <- stats::rlnorm(n, clin$icu_los$meanlog, clin$icu_los$sdlog)
  los <- pmax(1, pmin(clin$max_follow_up_days, ceiling(raw_los)))
  los <- ifelse(died_by_30, pmin(los, death_day + 1), los)

  transferred <- stats::rbinom(n, 1, clin$transfer_probability) == 1
  # A transfer only means anything if the stay is long enough to have a middle.
  transferred <- transferred & los >= 4
  transfer_day <- ifelse(transferred, ceiling(los / 2), NA_real_)

  # Readmission applies only to those discharged alive with window remaining.
  can_readmit <- !died_by_30 & los < clin$outcome_window_days - 2
  readmitted <- stats::rbinom(n, 1, clin$readmission_probability) == 1 & can_readmit
  readmit_gap <- ceiling(stats::runif(n, 2, 8))
  readmit_day <- ifelse(readmitted, los + readmit_gap, NA_real_)
  readmit_los <- ifelse(readmitted, ceiling(stats::runif(n, 1, 6)), NA_real_)
  # Do not let a readmission run past the end of follow-up.
  readmit_los <- ifelse(!is.na(readmit_day) &
                          readmit_day + readmit_los > clin$max_follow_up_days,
                        clin$max_follow_up_days - readmit_day, readmit_los)
  still_valid <- is.na(readmit_day) | readmit_los >= 1
  readmit_day[!still_valid] <- NA_real_
  readmit_los[!still_valid] <- NA_real_

  data.frame(
    participant_id  = enrolled$participant_id,
    site_id         = enrolled$site_id,
    index_datetime  = index_datetime,
    index_date      = index_date,
    severity_score  = severity,
    weight_kg       = enrolled$weight_kg,
    died_by_30      = died_by_30,
    death_day       = death_day,
    icu_los         = los,
    transfer_day    = transfer_day,
    readmit_day     = readmit_day,
    readmit_los     = readmit_los,
    stringsAsFactors = FALSE
  )
}
