# ---------------------------------------------------------------------------
# Defect injection.
#
# The clean dataset produced by simulate_trial() is deliberately corrupted with
# catalogued data-quality problems. Every injected defect is recorded in a
# ground-truth table so that the validation engine can be scored against it:
# without ground truth, "the rules found 400 problems" is an unfalsifiable
# claim.
#
# Each injector takes the current forms and its own config block, and returns
# the modified forms plus the ground-truth rows it created.
# ---------------------------------------------------------------------------

#' Construct ground-truth rows describing injected defects
#'
#' @param spec The defect's config block, supplying id and expected rule.
#' @param form Form the defect was injected into.
#' @param field Field affected, or NA for whole-record defects.
#' @param participant_id Participants affected.
#' @param site_id Sites affected.
#' @param record_key Human-readable key identifying the affected record.
#' @param original_value,injected_value Values before and after, as character.
#' @return A data frame of ground-truth rows.
defect_rows <- function(spec, form, field, participant_id, site_id,
                        record_key = NA_character_,
                        original_value = NA_character_,
                        injected_value = NA_character_) {
  data.frame(
    defect_id        = spec$id,
    defect_name      = spec$name,
    form             = form,
    field            = field,
    participant_id   = participant_id,
    site_id          = site_id,
    record_key       = record_key,
    expected_rule_id = if (is.null(spec$expected_rule_id)) NA_character_ else spec$expected_rule_id,
    original_value   = as.character(original_value),
    injected_value   = as.character(injected_value),
    stringsAsFactors = FALSE
  )
}

#' Fields eligible to be blanked by the missing-data injector
#'
#' Derived from the schema rather than hard-coded: any required field that is
#' not part of the record key and not an identifier.
#'
#' Identifiers are excluded deliberately. A record whose own identifier is
#' blank is not a record with a missing value -- it is an unlinkable orphan,
#' which is a structurally different defect requiring a different rule and a
#' different remediation. Blanking `record_id` also silently breaks every join
#' and every ordering downstream, which is how it was first noticed here: the
#' export/ingest round-trip stopped matching because rows could no longer be
#' aligned by key.
#'
#' `entry_date` is excluded because it is stamped by the EDC, not typed by a
#' human, so it cannot be left blank at entry.
#'
#' @param form Form name.
#' @return Character vector of field names.
blankable_fields <- function(form) {
  schema <- load_schema(form)
  required <- vapply(schema$columns, function(c) isTRUE(c$required), logical(1))
  names <- vapply(schema$columns, function(c) c$name, character(1))
  identifiers <- grep("_id$", names, value = TRUE)
  structural <- c(unlist(schema$key), identifiers, "entry_date")
  setdiff(names[required], structural)
}

#' D01: blank required fields, at site-specific rates
#'
#' One site is configured to be far worse than the rest. This is the defect a
#' completeness report is supposed to surface, and the site-specific rate is
#' what makes a per-site breakdown worth producing at all.
inject_missing_required <- function(forms, cfg, spec) {
  ground_truth <- list()

  for (form in unlist(spec$forms)) {
    data <- forms[[form]]
    fields <- blankable_fields(form)
    rate <- rep(spec$base_rate, nrow(data))
    for (site in names(spec$site_rates)) {
      rate[data$site_id == site] <- spec$site_rates[[site]]
    }

    for (field in fields) {
      hit <- stats::rbinom(nrow(data), 1, rate) == 1
      if (!any(hit)) next
      original <- data[[field]][hit]
      data[[field]][hit] <- NA
      ground_truth[[paste(form, field)]] <- defect_rows(
        spec, form, field,
        participant_id = data$participant_id[hit],
        site_id        = data$site_id[hit],
        record_key     = as.character(data[[unlist(load_schema(form)$key)[1]]][hit]),
        original_value = original,
        injected_value = NA_character_
      )
    }
    forms[[form]] <- data
  }
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D02: delete daily records from the middle of an ICU stay
#'
#' A gap, not a truncation. Truncation looks like discharge; a gap is
#' unexplained and is exactly the case where "no record" must not be read as
#' "no life support".
inject_daily_gaps <- function(forms, cfg, spec) {
  daily <- forms$daily_icu
  stays <- table(daily$participant_id)
  # Only stays long enough to have a middle can carry a gap.
  eligible <- names(stays)[stays >= 5]
  n_pick <- max(1, round(length(eligible) * spec$participant_rate))
  picked <- sample(eligible, n_pick)

  gap_range <- unlist(spec$gap_length_days)
  drop_rows <- integer(0)
  ground_truth <- list()

  for (pid in picked) {
    rows <- which(daily$participant_id == pid)
    days <- daily$icu_day[rows]
    gap_len <- sample(seq(gap_range[1], gap_range[2]), 1)
    # Leave at least one day at each end so the gap is interior.
    interior <- days[days > min(days) & days < max(days)]
    if (length(interior) < gap_len) next
    start_at <- sample(seq_len(length(interior) - gap_len + 1), 1)
    gap_days <- interior[start_at:(start_at + gap_len - 1)]
    gone <- rows[days %in% gap_days]
    drop_rows <- c(drop_rows, gone)

    ground_truth[[pid]] <- defect_rows(
      spec, "daily_icu", NA_character_,
      participant_id = pid,
      site_id        = daily$site_id[rows][1],
      record_key     = paste0(pid, " days ", paste(gap_days, collapse = ",")),
      original_value = paste(gap_days, collapse = ","),
      injected_value = NA_character_
    )
  }

  forms$daily_icu <- daily[-drop_rows, ]
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D03: write physiologically impossible values
inject_out_of_range <- function(forms, cfg, spec) {
  ground_truth <- list()

  for (i in seq_along(spec$variants)) {
    variant <- spec$variants[[i]]
    data <- forms[[variant$form]]
    hit <- stats::rbinom(nrow(data), 1, spec$participant_rate) == 1
    if (!any(hit)) next

    original <- data[[variant$field]][hit]
    data[[variant$field]][hit] <- variant$value
    forms[[variant$form]] <- data

    ground_truth[[i]] <- defect_rows(
      spec, variant$form, variant$field,
      participant_id = data$participant_id[hit],
      site_id        = data$site_id[hit],
      record_key     = as.character(data[[unlist(load_schema(variant$form)$key)[1]]][hit]),
      original_value = original,
      injected_value = variant$value
    )
  }
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D11: weight measured in pounds, submitted as kilograms
#'
#' The site declares kg, so ingest applies no conversion and the value passes
#' through roughly 2.2x too high. This is a units failure that no amount of
#' schema checking catches -- only a plausibility range does.
inject_unit_failure <- function(forms, cfg, spec) {
  screening <- forms$screening
  at_site <- screening$site_id %in% unlist(spec$sites)
  hit <- at_site & stats::rbinom(nrow(screening), 1, spec$rate) == 1
  if (!any(hit)) return(list(forms = forms, defects = NULL))

  original <- screening$weight_kg[hit]
  screening$weight_kg[hit] <- round(original * spec$multiplier, 1)
  forms$screening <- screening

  list(
    forms = forms,
    defects = defect_rows(
      spec, "screening", "weight_kg",
      participant_id = screening$participant_id[hit],
      site_id        = screening$site_id[hit],
      record_key     = screening$screening_id[hit],
      original_value = original,
      injected_value = screening$weight_kg[hit]
    )
  )
}

#' D04: discharge recorded before ICU admission
inject_impossible_dates <- function(forms, cfg, spec) {
  outcome <- forms$outcome_30d
  eligible <- which(!is.na(outcome$hospital_discharge_date))
  n_pick <- max(1, round(length(eligible) * spec$participant_rate))
  picked <- sample(eligible, n_pick)

  shift <- unlist(spec$shift_days)
  original <- outcome$hospital_discharge_date[picked]
  outcome$hospital_discharge_date[picked] <-
    outcome$icu_admission_date[picked] +
    sample(seq(shift[1], shift[2]), length(picked), replace = TRUE)
  forms$outcome_30d <- outcome

  list(
    forms = forms,
    defects = defect_rows(
      spec, "outcome_30d", "hospital_discharge_date",
      participant_id = outcome$participant_id[picked],
      site_id        = outcome$site_id[picked],
      record_key     = paste(outcome$participant_id[picked], outcome$domain[picked]),
      original_value = format(original),
      injected_value = format(outcome$hospital_discharge_date[picked])
    )
  )
}

#' D05: adverse event onset before randomisation
inject_ae_before_randomisation <- function(forms, cfg, spec) {
  ae <- forms$adverse_events
  first_rand <- stats::aggregate(randomisation_datetime ~ participant_id,
                                 data = forms$randomisation, FUN = min)

  hit <- which(stats::rbinom(nrow(ae), 1, spec$event_rate) == 1)
  if (length(hit) == 0) return(list(forms = forms, defects = NULL))

  shift <- unlist(spec$shift_days)
  rand_date <- as.Date(first_rand$randomisation_datetime[
    match(ae$participant_id[hit], first_rand$participant_id)])
  original <- ae$onset_date[hit]
  ae$onset_date[hit] <- rand_date +
    sample(seq(shift[1], shift[2]), length(hit), replace = TRUE)
  forms$adverse_events <- ae

  list(
    forms = forms,
    defects = defect_rows(
      spec, "adverse_events", "onset_date",
      participant_id = ae$participant_id[hit],
      site_id        = ae$site_id[hit],
      record_key     = ae$ae_id[hit],
      original_value = format(original),
      injected_value = format(ae$onset_date[hit])
    )
  )
}

#' D06: the same participant ID issued at two different sites
#'
#' Re-labels a participant at one site with an ID already in use at another.
#' Every form belonging to the victim is relabelled, so the duplicate is
#' internally consistent -- which is what makes it hard to spot without an
#' explicit key check.
inject_duplicate_ids <- function(forms, cfg, spec) {
  screening <- forms$screening
  enrolled <- screening[screening$enrolled == 1 & !is.na(screening$participant_id), ]
  ground_truth <- list()

  for (i in seq_len(spec$n_pairs)) {
    donor <- enrolled[sample(nrow(enrolled), 1), ]
    others <- enrolled[enrolled$site_id != donor$site_id, ]
    victim <- others[sample(nrow(others), 1), ]

    for (form in c("screening", "randomisation", "daily_icu",
                   "outcome_30d", "adverse_events")) {
      rows <- which(forms[[form]]$participant_id == victim$participant_id)
      if (length(rows)) forms[[form]]$participant_id[rows] <- donor$participant_id
    }

    ground_truth[[i]] <- defect_rows(
      spec, "screening", "participant_id",
      participant_id = donor$participant_id,
      site_id        = victim$site_id,
      record_key     = victim$screening_id,
      original_value = victim$participant_id,
      injected_value = donor$participant_id
    )
  }
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D07: one participant randomised twice within the same domain
inject_double_randomisation <- function(forms, cfg, spec) {
  rand <- forms$randomisation
  picked <- sample(nrow(rand), spec$n_participants)

  duplicates <- rand[picked, ]
  duplicates$randomisation_id <- sprintf("RND-9%05d", seq_len(nrow(duplicates)))
  # A second allocation a short while after the first.
  duplicates$randomisation_datetime <- duplicates$randomisation_datetime + 3600 * 6
  forms$randomisation <- rbind(rand, duplicates)

  list(
    forms = forms,
    defects = defect_rows(
      spec, "randomisation", "participant_id",
      participant_id = duplicates$participant_id,
      site_id        = duplicates$site_id,
      record_key     = duplicates$randomisation_id,
      original_value = NA_character_,
      injected_value = paste(duplicates$participant_id, duplicates$domain)
    )
  )
}

#' D08: alive on a daily record dated after the recorded date of death
#'
#' Adds daily records after the participant's death. The contradiction spans
#' two forms, so no amount of within-form checking finds it -- it needs a
#' cross-form rule.
inject_vital_status_conflict <- function(forms, cfg, spec) {
  outcome <- forms$outcome_30d
  daily <- forms$daily_icu

  dead <- unique(outcome$participant_id[outcome$vital_status_30d == "dead" &
                                          !is.na(outcome$death_date)])
  dead <- dead[dead %in% daily$participant_id]
  picked <- sample(dead, min(spec$n_participants, length(dead)))

  extra_range <- unlist(spec$alive_days_after_death)
  new_rows <- list()
  ground_truth <- list()

  for (pid in picked) {
    rows <- daily[daily$participant_id == pid, ]
    last <- rows[which.max(rows$icu_day), ]
    n_extra <- sample(seq(extra_range[1], extra_range[2]), 1)

    added <- last[rep(1, n_extra), ]
    added$icu_day <- last$icu_day + seq_len(n_extra)
    added$record_date <- last$record_date + seq_len(n_extra)
    added$entry_date <- last$entry_date + seq_len(n_extra)
    added$alive <- 1L
    added$record_id <- sprintf("DLY-9%06d", seq_len(n_extra) + length(new_rows) * 10)
    new_rows[[pid]] <- added

    death_date <- outcome$death_date[outcome$participant_id == pid][1]
    ground_truth[[pid]] <- defect_rows(
      spec, "daily_icu", "alive",
      participant_id = pid,
      site_id        = last$site_id,
      record_key     = paste0(pid, " days ", paste(added$icu_day, collapse = ",")),
      original_value = paste("death_date", format(death_date)),
      injected_value = paste("alive on", paste(format(added$record_date), collapse = ","))
    )
  }

  forms$daily_icu <- rbind(daily, do.call(rbind, new_rows))
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D09: entry delay worsening over time at one site
#'
#' The key drift signal. A single cross-sectional timeliness number hides it
#' completely; only a trend over time exposes it.
inject_entry_drift <- function(forms, cfg, spec) {
  sites <- resolve_sites(cfg)
  ground_truth <- list()

  for (site in unlist(spec$sites)) {
    initiation <- sites$initiation_date[sites$site_id == site]

    for (form in c("screening", "randomisation", "daily_icu",
                   "outcome_30d", "adverse_events")) {
      data <- forms[[form]]
      rows <- which(data$site_id == site)
      if (!length(rows)) next

      months_open <- as.numeric(data$entry_date[rows] - initiation) / 30.44
      extra <- ceiling(pmax(0, months_open) * spec$extra_delay_per_month)
      data$entry_date[rows] <- data$entry_date[rows] + extra
      forms[[form]] <- data

      ground_truth[[paste(site, form)]] <- defect_rows(
        spec, form, "entry_date",
        participant_id = data$participant_id[rows],
        site_id        = site,
        record_key     = as.character(data[[unlist(load_schema(form)$key)[1]]][rows]),
        original_value = NA_character_,
        injected_value = as.character(extra)
      )
    }
  }
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D10: terminal-digit preference at one site
#'
#' Values ending in 0 or 5 far more often than chance, the classic signature of
#' estimated rather than measured observations.
inject_terminal_digits <- function(forms, cfg, spec) {
  ground_truth <- list()
  field_forms <- list(heart_rate = "daily_icu", weight_kg = "screening")

  for (site in unlist(spec$sites)) {
    for (field in unlist(spec$fields)) {
      form <- field_forms[[field]]
      data <- forms[[form]]
      rows <- which(data$site_id == site & !is.na(data[[field]]))
      if (!length(rows)) next

      hit <- rows[stats::rbinom(length(rows), 1, spec$rate) == 1]
      if (!length(hit)) next

      original <- data[[field]][hit]
      data[[field]][hit] <- round(original / 5) * 5
      forms[[form]] <- data

      ground_truth[[paste(site, field)]] <- defect_rows(
        spec, form, field,
        participant_id = data$participant_id[hit],
        site_id        = site,
        record_key     = as.character(data[[unlist(load_schema(form)$key)[1]]][hit]),
        original_value = original,
        injected_value = data[[field]][hit]
      )
    }
  }
  list(forms = forms, defects = do.call(rbind, ground_truth))
}

#' D12: one site systematically under-reporting adverse events
inject_ae_under_reporting <- function(forms, cfg, spec) {
  ae <- forms$adverse_events
  at_site <- which(ae$site_id %in% unlist(spec$sites))
  if (!length(at_site)) return(list(forms = forms, defects = NULL))

  keep <- stats::rbinom(length(at_site), 1, spec$retention_fraction) == 1
  dropped <- at_site[!keep]
  if (!length(dropped)) return(list(forms = forms, defects = NULL))

  ground_truth <- defect_rows(
    spec, "adverse_events", NA_character_,
    participant_id = ae$participant_id[dropped],
    site_id        = ae$site_id[dropped],
    record_key     = ae$ae_id[dropped],
    original_value = ae$ae_code[dropped],
    injected_value = NA_character_
  )

  forms$adverse_events <- ae[-dropped, ]
  list(forms = forms, defects = ground_truth)
}

# Dispatch table: defect name in config -> injector function.
DEFECT_INJECTORS <- list(
  missing_required_field           = inject_missing_required,
  missing_daily_record_gap         = inject_daily_gaps,
  out_of_range_value               = inject_out_of_range,
  unit_conversion_failure          = inject_unit_failure,
  impossible_date_sequence         = inject_impossible_dates,
  ae_before_randomisation          = inject_ae_before_randomisation,
  duplicate_participant_id         = inject_duplicate_ids,
  double_randomisation_same_domain = inject_double_randomisation,
  inconsistent_vital_status        = inject_vital_status_conflict,
  late_entry_drift                 = inject_entry_drift,
  terminal_digit_preference        = inject_terminal_digits,
  ae_under_reporting               = inject_ae_under_reporting
)

#' Inject every configured defect and return the ground-truth catalogue
#'
#' Injectors run in the order they appear in config. Order matters: defects
#' that add records (double randomisation, post-death daily rows) run before
#' those that operate on whole columns, so the added records are themselves
#' exposed to later injectors, as they would be in reality.
#'
#' Assumes each defect in config has a matching entry in `DEFECT_INJECTORS`.
#'
#' @param forms Clean forms from [simulate_trial()].
#' @param cfg Trial configuration.
#' @return A list with `forms` (corrupted) and `defects` (ground truth).
inject_defects <- function(forms, cfg) {
  set.seed(cfg$trial$seed + 1)
  catalogue <- list()

  for (spec in cfg$defects) {
    injector <- DEFECT_INJECTORS[[spec$name]]
    if (is.null(injector)) {
      stop("No injector registered for defect '", spec$name, "'.")
    }
    result <- injector(forms, cfg, spec)
    forms <- result$forms
    if (!is.null(result$defects)) catalogue[[spec$id]] <- result$defects
  }

  list(forms = forms, defects = do.call(rbind, catalogue))
}

#' Summarise the injected-defect catalogue
#'
#' @param defects Ground-truth table from [inject_defects()].
#' @return A data frame with one row per defect type.
defect_catalogue_summary <- function(defects) {
  out <- stats::aggregate(
    cbind(records = rep(1, nrow(defects))) ~ defect_id + defect_name + expected_rule_id,
    data = transform(defects,
                     expected_rule_id = ifelse(is.na(expected_rule_id),
                                               "(no rule - monitoring signal)",
                                               expected_rule_id)),
    FUN = sum
  )
  out[order(out$defect_id), c("defect_id", "defect_name", "expected_rule_id", "records")]
}
