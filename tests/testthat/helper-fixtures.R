# ---------------------------------------------------------------------------
# Fixtures for rule tests.
#
# Rules are tested through the real engine against the real YAML, not against a
# re-implementation of the expression in R. A test that restates the rule in
# the test file proves only that two copies of the same mistake agree.
#
# Every fixture starts CLEAN -- a dataset that should produce no findings at
# all. Each test then breaks exactly one thing and asserts that exactly the
# expected rule fires. That the clean fixture is silent is itself a test, and a
# strong one: it is what catches a rule that fires on correct data.
# ---------------------------------------------------------------------------

FIXTURE_DATE <- as.Date("2025-03-10")

#' Build one valid row for a form, from its schema
#'
#' Every column defined in the schema is populated with a value that satisfies
#' its declared type and bounds, so a fixture never fails a rule by accident.
#' Named arguments override individual fields.
#'
#' @param form Form name.
#' @param ... Field overrides.
#' @return A one-row data frame.
fixture_row <- function(form, ...) {
  schema <- load_schema(form)
  overrides <- list(...)

  row <- lapply(schema$columns, function(spec) {
    if (!is.null(overrides[[spec$name]])) return(overrides[[spec$name]])

    switch(
      spec$type,
      date = FIXTURE_DATE,
      datetime = as.POSIXct(paste(FIXTURE_DATE, "09:00:00"), tz = "UTC"),
      integer = {
        low <- spec$min %||% 1
        high <- spec$max %||% (low + 10)
        as.integer(floor((low + high) / 2))
      },
      number = {
        low <- spec$min %||% 1
        high <- spec$max %||% (low + 10)
        (low + high) / 2
      },
      code = {
        allowed <- unlist(spec$allowed)
        if (is.null(allowed)) "X" else {
          numeric_codes <- !any(is.na(suppressWarnings(as.numeric(allowed))))
          if (numeric_codes) as.integer(allowed[1]) else allowed[1]
        }
      },
      character = "X",
      stop("Unhandled fixture type: ", spec$type)
    )
  })
  names(row) <- vapply(schema$columns, function(c) c$name, character(1))
  as.data.frame(row, stringsAsFactors = FALSE)
}

#' A complete, internally consistent, defect-free dataset
#'
#' One participant, randomised into one domain, with three consecutive ICU
#' days, a 30-day outcome and one adverse event. Small enough to reason about
#' entirely, complete enough for every rule to evaluate.
#'
#' @return A named list of five forms.
fixture_forms <- function() {
  participant <- "P-000001"
  site <- "DK-01"

  screening <- fixture_row(
    "screening",
    screening_id = "SCR-000001", participant_id = participant, site_id = site,
    screening_date = FIXTURE_DATE, entry_date = FIXTURE_DATE + 1,
    age_years = 64L, weight_kg = 80, creatinine = 95, severity_score = 22L,
    enrolled = 1L
  )

  randomisation <- fixture_row(
    "randomisation",
    randomisation_id = "RND-000001", participant_id = participant, site_id = site,
    domain = "FLUID", arm = "restrictive",
    randomisation_datetime = as.POSIXct(paste(FIXTURE_DATE, "12:00:00"), tz = "UTC"),
    allocation_ratio = "1:1", entry_date = FIXTURE_DATE + 1
  )

  daily_icu <- do.call(rbind, lapply(0:2, function(day) {
    fixture_row(
      "daily_icu",
      record_id = sprintf("DLY-000000%d", day + 1),
      participant_id = participant, site_id = site,
      icu_day = as.integer(day), record_date = FIXTURE_DATE + day,
      alive = 1L, in_icu = 1L,
      mechanical_ventilation = 0L, vasopressors = 0L, renal_replacement = 0L,
      icu_location = "DK-01-ICU1", heart_rate = 82L, temperature_c = 37.0,
      entry_date = FIXTURE_DATE + day + 1
    )
  }))

  outcome_30d <- fixture_row(
    "outcome_30d",
    participant_id = participant, domain = "FLUID", site_id = site,
    vital_status_30d = "alive", death_date = as.Date(NA),
    icu_admission_date = FIXTURE_DATE,
    hospital_discharge_date = FIXTURE_DATE + 8,
    entry_date = FIXTURE_DATE + 9
  )

  adverse_events <- fixture_row(
    "adverse_events",
    ae_id = "AE-000001", participant_id = participant, site_id = site,
    ae_code = "AE-INFECT", onset_date = FIXTURE_DATE + 1,
    serious = 0L, related = 0L, entry_date = FIXTURE_DATE + 2
  )

  list(screening = screening, randomisation = randomisation,
       daily_icu = daily_icu, outcome_30d = outcome_30d,
       adverse_events = adverse_events)
}

#' Run the real rule set against a fixture
#'
#' @param forms Fixture forms, optionally perturbed.
#' @param rule_id Restrict to a single rule; NULL runs all of them.
#' @return A findings table.
validate_fixture <- function(forms, rule_id = NULL) {
  rules <- load_rules()
  if (!is.null(rule_id)) {
    rules <- Filter(function(r) r$id %in% rule_id, rules)
    if (!length(rules)) stop("No such rule: ", rule_id)
  }
  sites <- resolve_sites(test_config())
  run_validation(forms, sites, rules)
}

#' Rule ids that fired against a fixture
#'
#' @param forms Fixture forms.
#' @param rule_id Restrict to a single rule; NULL runs all.
#' @return Character vector of rule ids, sorted and deduplicated.
fired_rules <- function(forms, rule_id = NULL) {
  sort(unique(validate_fixture(forms, rule_id)$rule_id))
}
