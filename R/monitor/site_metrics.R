# ---------------------------------------------------------------------------
# Metrics for the site monitoring report.
#
# Two principles run through this file, and both come from how monitoring
# reports actually get used:
#
#   1. TRENDS, NOT SNAPSHOTS. "94% complete" tells a coordinator nothing they
#      can act on. "94%, down from 99% over four months" tells them to make a
#      phone call. A single number cannot show a site getting worse, and a site
#      getting worse is the thing worth catching.
#
#   2. TIME SINCE INITIATION, NOT CALENDAR TIME. Sites opened nine to twelve
#      months apart. Comparing a site in its second month against one in its
#      twentieth on the same calendar axis penalises the new site for being
#      new, which is both unfair and useless -- everybody already knows it is
#      new.
# ---------------------------------------------------------------------------

#' Required fields for a form, excluding identifiers
#'
#' Completeness is measured over the fields a human fills in. Identifiers and
#' EDC-stamped dates are always present by construction and would dilute the
#' measure toward 100%.
#'
#' @param form Form name.
#' @return Character vector of field names.
completeness_fields <- function(form) {
  schema <- load_schema(form)
  names <- vapply(schema$columns, function(c) c$name, character(1))
  required <- vapply(schema$columns, function(c) isTRUE(c$required), logical(1))
  setdiff(names[required], c(grep("_id$", names, value = TRUE), "entry_date"))
}

#' Month-level completeness by form and site
#'
#' Completeness is the proportion of required, human-entered fields that carry
#' a value, measured against the month of the clinical event rather than the
#' month of entry -- otherwise a site that enters late appears to have no data
#' problem at all, merely a later one.
#'
#' @param forms Conformed forms.
#' @return A data frame with `site_id`, `form`, `month`, `fields_expected`,
#'   `fields_present` and `completeness`.
completeness_by_month <- function(forms) {
  rows <- lapply(names(forms), function(form) {
    data <- forms[[form]]
    fields <- completeness_fields(form)
    if (!length(fields)) return(NULL)

    event_date <- as.Date(data[[event_date_column(form)]])
    present <- rowSums(!is.na(data[, fields, drop = FALSE]))

    data.frame(
      site_id = data$site_id,
      form = form,
      month = as.Date(format(event_date, "%Y-%m-01")),
      fields_expected = length(fields),
      fields_present = present,
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows) |>
    dplyr::filter(!is.na(month)) |>
    dplyr::group_by(site_id, form, month) |>
    dplyr::summarise(
      records = dplyr::n(),
      fields_expected = sum(fields_expected),
      fields_present = sum(fields_present),
      .groups = "drop"
    ) |>
    dplyr::mutate(completeness = fields_present / fields_expected) |>
    as.data.frame()
}

#' Month-level data entry timeliness by site
#'
#' Reports the median delay from clinical event to EDC entry, and alongside it
#' the proportion of records whose event fell near a public holiday in that
#' site's own country. A Danish site in late December and a Dutch site in the
#' same week are not comparable on a single global scale, and a report that
#' compares them anyway will generate a query that wastes everybody's time.
#'
#' @param forms Conformed forms.
#' @param cfg Trial configuration.
#' @param sites Resolved site table.
#' @return A data frame of monthly timeliness by site and form.
timeliness_by_month <- function(forms, cfg, sites) {
  calendar <- holiday_calendar(cfg)
  window <- cfg$timeliness$holiday_window_days

  rows <- lapply(names(forms), function(form) {
    data <- forms[[form]]
    event_date <- as.Date(data[[event_date_column(form)]])
    delay <- as.numeric(data$entry_date - event_date)
    country <- sites$country[match(data$site_id, sites$site_id)]

    near <- rep(FALSE, nrow(data))
    for (code in unique(country[!is.na(country)])) {
      at_country <- which(country == code)
      near[at_country] <- near_holiday(event_date[at_country], code,
                                       calendar, window)
    }

    data.frame(
      site_id = data$site_id,
      country = country,
      form = form,
      month = as.Date(format(event_date, "%Y-%m-01")),
      delay_days = delay,
      near_holiday = near,
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows) |>
    dplyr::filter(!is.na(month), !is.na(delay_days)) |>
    dplyr::group_by(site_id, country, form, month) |>
    dplyr::summarise(
      records = dplyr::n(),
      median_delay_days = stats::median(delay_days),
      p90_delay_days = stats::quantile(delay_days, 0.9, names = FALSE),
      holiday_affected = mean(near_holiday),
      .groups = "drop"
    ) |>
    as.data.frame()
}

#' Re-express monthly metrics against months since site initiation
#'
#' This is what makes a young site comparable to an established one. A site in
#' its third month is compared against every other site's third month, not
#' against their present.
#'
#' @param monthly A data frame carrying `site_id` and `month`.
#' @param sites Resolved site table.
#' @return `monthly` with a `months_since_initiation` column.
add_months_since_initiation <- function(monthly, sites) {
  initiation <- sites$initiation_date[match(monthly$site_id, sites$site_id)]
  monthly$months_since_initiation <-
    floor(as.numeric(monthly$month - as.Date(format(initiation, "%Y-%m-01"))) / 30.44)
  monthly[monthly$months_since_initiation >= 0, ]
}

#' Compare one site against all others at the same stage of participation
#'
#' @param monthly Output of [completeness_by_month()] or similar.
#' @param sites Resolved site table.
#' @param site_id The site being reported on.
#' @param value_column Column to compare.
#' @return A data frame with the site's value and the all-site median at each
#'   month since initiation.
compare_to_all_sites <- function(monthly, sites, site_id, value_column) {
  staged <- add_months_since_initiation(monthly, sites)

  all_sites <- staged |>
    dplyr::group_by(months_since_initiation) |>
    dplyr::summarise(
      all_sites_median = stats::median(.data[[value_column]], na.rm = TRUE),
      all_sites_lower = stats::quantile(.data[[value_column]], 0.25, na.rm = TRUE, names = FALSE),
      all_sites_upper = stats::quantile(.data[[value_column]], 0.75, na.rm = TRUE, names = FALSE),
      .groups = "drop"
    )

  this_site <- staged |>
    dplyr::filter(site_id == !!site_id) |>
    dplyr::group_by(months_since_initiation) |>
    dplyr::summarise(this_site = stats::median(.data[[value_column]], na.rm = TRUE),
                     .groups = "drop")

  dplyr::left_join(all_sites, this_site, by = "months_since_initiation") |>
    as.data.frame()
}

#' Open findings for a site, ordered for action
#'
#' Critical first, then by age. The participant identifier is carried through
#' deliberately: a finding a coordinator cannot trace to a specific record is a
#' statistic, not a task.
#'
#' @param findings Findings table.
#' @param site_id Site to filter to.
#' @return A data frame of that site's findings.
site_findings_detail <- function(findings, site_id) {
  out <- findings[findings$site_id == site_id, ]
  if (!nrow(out)) return(out)
  out$severity <- factor(out$severity, levels = VALID_SEVERITIES)
  out[order(out$severity, out$rule_id, out$participant_id), ]
}

#' The plain-language actions for a site this week
#'
#' The list a coordinator reads first and the only part of the report that has
#' to be read at all. Each item names what to do, how many records it concerns,
#' and why it matters -- not merely which rule fired.
#'
#' Ordering is by consequence, not by count: a single participant randomised
#' twice matters more than two hundred blank temperature fields.
#'
#' @param findings Findings for this site.
#' @param endpoint Endpoint table for this site.
#' @param completeness Monthly completeness for this site.
#' @param max_actions Most actions to return.
#' @return A data frame with `priority`, `action`, `records` and `why`.
site_actions <- function(findings, endpoint, completeness, max_actions = 8) {
  actions <- list()

  add <- function(action, records, why) {
    actions[[length(actions) + 1]] <<- data.frame(
      action = action, records = records, why = why, stringsAsFactors = FALSE)
  }

  # 1. Critical findings, grouped by rule, are always first.
  critical <- findings[findings$severity == "critical", ]
  if (nrow(critical)) {
    by_rule <- critical |>
      dplyr::group_by(rule_id, rule_name) |>
      dplyr::summarise(n = dplyr::n(), .groups = "drop") |>
      dplyr::arrange(dplyr::desc(n))
    rules <- load_rules()
    for (i in seq_len(nrow(by_rule))) {
      rule <- Filter(function(r) r$id == by_rule$rule_id[i], rules)[[1]]
      add(paste0("Resolve ", by_rule$rule_id[i], ": ",
                 gsub("_", " ", by_rule$rule_name[i])),
          by_rule$n[i],
          trimws(gsub("\\s+", " ", rule$description)))
    }
  }

  # 2. Endpoint records that cannot be evaluated at all.
  if (nrow(endpoint)) {
    not_evaluable <- sum(is.na(endpoint$days_alive_without_life_support))
    if (not_evaluable > 0) {
      add("Supply the missing randomisation date and time", not_evaluable,
          paste("The primary endpoint cannot be calculated for these",
                "participants at all, so they are absent from the analysis."))
    }
    incomplete <- sum(!endpoint$complete &
                        !is.na(endpoint$days_alive_without_life_support))
    if (incomplete > 0) {
      add("Complete the missing daily ICU records", incomplete,
          paste("Days with no record are counted as unknown, not as days free",
                "of life support, so the primary endpoint is understated for",
                "these participants."))
    }
  }

  # 3. Completeness that is falling rather than merely low.
  if (nrow(completeness) >= 2) {
    recent <- completeness |>
      dplyr::group_by(form) |>
      dplyr::arrange(month) |>
      dplyr::summarise(
        latest = dplyr::last(completeness),
        earlier = dplyr::first(completeness),
        .groups = "drop"
      ) |>
      dplyr::mutate(change = latest - earlier) |>
      dplyr::filter(change < -0.02) |>
      dplyr::arrange(change)

    for (i in seq_len(nrow(recent))) {
      add(paste0("Review data entry on the ", gsub("_", " ", recent$form[i]),
                 " form"), NA_integer_,
          sprintf(paste("Completeness has fallen from %.1f%% to %.1f%% over the",
                        "period shown. A downward trend is a process problem,",
                        "not a backlog."),
                  100 * recent$earlier[i], 100 * recent$latest[i]))
    }
  }

  if (!length(actions)) {
    return(data.frame(priority = integer(), action = character(),
                      records = integer(), why = character(),
                      stringsAsFactors = FALSE))
  }

  out <- do.call(rbind, actions)
  out <- utils::head(out, max_actions)
  out$priority <- seq_len(nrow(out))
  out[, c("priority", "action", "records", "why")]
}

#' Detect sites whose data entry is getting slower
#'
#' Fits a straight line to each site's median entry delay against months since
#' its own initiation, and reports the slope in days-per-month.
#'
#' This exists because no row-level validation rule can catch drift. Every
#' individual record at a drifting site is perfectly valid: it was entered
#' late, which is not a rule violation. Only the trend across months shows that
#' the site is falling further behind, and only a comparison against its own
#' start shows it is not simply a young site still settling in.
#'
#' A positive slope means the site is getting slower. Twenty open queries is
#' normal; twenty that are getting older every month means nobody is reading
#' them.
#'
#' @param timeliness Output of [timeliness_by_month()].
#' @param sites Resolved site table.
#' @param min_months Fewest months of data needed to fit a trend.
#' @return A data frame ordered by slope, worst first.
entry_delay_trend <- function(timeliness, sites, min_months = 6) {
  monthly <- timeliness |>
    dplyr::group_by(site_id, country, month) |>
    dplyr::summarise(median_delay_days = stats::median(median_delay_days),
                     .groups = "drop")

  staged <- add_months_since_initiation(monthly, sites)

  staged |>
    dplyr::group_by(site_id, country) |>
    dplyr::filter(dplyr::n() >= min_months) |>
    dplyr::summarise(
      months_observed = dplyr::n(),
      first_median_days = round(dplyr::first(median_delay_days[order(months_since_initiation)]), 1),
      last_median_days = round(dplyr::last(median_delay_days[order(months_since_initiation)]), 1),
      slope_days_per_month = round(
        stats::coef(stats::lm(median_delay_days ~ months_since_initiation))[2], 2),
      .groups = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(slope_days_per_month)) |>
    as.data.frame()
}

#' Sites ranked by the attention they need
#'
#' Combines critical findings, endpoint evaluability and entry-delay drift into
#' one ordered list. Deliberately not a single composite score: a score hides
#' which of the three is the problem, and the coordinating centre needs to know
#' which call to make.
#'
#' @param findings Findings table.
#' @param endpoint Endpoint table.
#' @param drift Output of [entry_delay_trend()].
#' @param sites Resolved site table.
#' @return A data frame, one row per site.
sites_needing_attention <- function(findings, endpoint, drift, sites) {
  critical <- findings |>
    dplyr::filter(severity == "critical") |>
    dplyr::group_by(site_id) |>
    dplyr::summarise(critical_findings = dplyr::n(), .groups = "drop")

  endpoint_quality <- endpoint |>
    dplyr::group_by(site_id) |>
    dplyr::summarise(
      records = dplyr::n(),
      not_evaluable = sum(is.na(days_alive_without_life_support)),
      pct_incomplete = round(100 * mean(!complete), 1),
      .groups = "drop"
    )

  sites[, c("site_id", "site_name", "country", "initiation_date")] |>
    dplyr::left_join(critical, by = "site_id") |>
    dplyr::left_join(endpoint_quality, by = "site_id") |>
    dplyr::left_join(drift[, c("site_id", "slope_days_per_month")], by = "site_id") |>
    dplyr::mutate(critical_findings = dplyr::coalesce(critical_findings, 0L)) |>
    dplyr::arrange(dplyr::desc(slope_days_per_month), dplyr::desc(critical_findings)) |>
    as.data.frame()
}
