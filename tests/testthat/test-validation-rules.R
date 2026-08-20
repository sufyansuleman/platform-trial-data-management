# Every rule expression in config/rules/*.yml is exercised here, through the
# real engine against the real YAML. Each test breaks one thing in an otherwise
# clean dataset and asserts that the expected rule fires.

# --- The engine and the rule set itself ------------------------------------

test_that("the rule set loads and every rule declares what the engine needs", {
  rules <- load_rules()
  expect_gt(length(rules), 0)
  for (rule in rules) {
    for (field in c("id", "name", "scope", "severity", "description",
                    "rationale", "expression", "action")) {
      expect_false(is.null(rule[[field]]),
                   info = paste(rule$id, "is missing", field))
    }
    expect_true(rule$severity %in% VALID_SEVERITIES, info = rule$id)
  }
})

test_that("rule ids are unique across all rule files", {
  ids <- vapply(load_rules(), function(r) r$id, character(1))
  expect_equal(anyDuplicated(ids), 0)
})

test_that("the rule set version changes when the rules change", {
  original <- rule_set_version()
  temporary <- file.path(tempdir(), "rules_copy")
  dir.create(temporary, showWarnings = FALSE)
  file.copy(list.files(project_path("config", "rules"), full.names = TRUE),
            temporary, overwrite = TRUE)
  expect_equal(rule_set_version(temporary), original)

  cat("\n# a change\n", file = file.path(temporary, "range.yml"), append = TRUE)
  expect_false(identical(rule_set_version(temporary), original))
})

test_that("a clean dataset produces no findings at all", {
  # The single most important test in this file. A rule that fires on correct
  # data floods the coordinator with noise and trains them to ignore findings.
  expect_equal(nrow(validate_fixture(fixture_forms())), 0)
})

# --- Structural -------------------------------------------------------------

test_that("STR-001 fires on a missing required field, and names it", {
  forms <- fixture_forms()
  forms$screening$age_years <- NA_integer_
  findings <- validate_fixture(forms, "STR-001")
  expect_equal(nrow(findings), 1)
  expect_equal(findings$field, "age_years")
  expect_equal(findings$form, "screening")
  expect_equal(findings$severity, "major")
})

test_that("STR-001 ignores an optional field left blank", {
  forms <- fixture_forms()
  forms$daily_icu$temperature_c <- NA_real_   # optional in the schema
  expect_equal(nrow(validate_fixture(forms, "STR-001")), 0)
})

test_that("STR-002 fires when a follow-up form references an unrandomised participant", {
  forms <- fixture_forms()
  forms$adverse_events$participant_id <- "P-999999"
  expect_true("STR-002" %in% fired_rules(forms, "STR-002"))
})

test_that("STR-003 fires when one participant id is used at two sites", {
  forms <- fixture_forms()
  second <- forms$screening
  second$screening_id <- "SCR-000002"
  second$site_id <- "DK-02"          # same participant_id, different site
  forms$screening <- rbind(forms$screening, second)

  findings <- validate_fixture(forms, "STR-003")
  expect_equal(nrow(findings), 2)    # both records are implicated
  expect_equal(unique(findings$severity), "critical")
})

test_that("STR-004 fires on a second randomisation in the same domain", {
  forms <- fixture_forms()
  second <- forms$randomisation
  second$randomisation_id <- "RND-000002"
  forms$randomisation <- rbind(forms$randomisation, second)
  expect_equal(nrow(validate_fixture(forms, "STR-004")), 2)
})

test_that("STR-004 does not fire on randomisation into a different domain", {
  forms <- fixture_forms()
  second <- forms$randomisation
  second$randomisation_id <- "RND-000002"
  second$domain <- "ANTICOAG"
  forms$randomisation <- rbind(forms$randomisation, second)
  expect_equal(nrow(validate_fixture(forms, "STR-004")), 0)
})

# --- Range ------------------------------------------------------------------

test_that("RNG-001 fires on an implausible weight in either direction", {
  forms <- fixture_forms()
  forms$screening$weight_kg <- 8
  expect_equal(nrow(validate_fixture(forms, "RNG-001")), 1)

  forms$screening$weight_kg <- 300
  expect_equal(nrow(validate_fixture(forms, "RNG-001")), 1)
})

test_that("RNG-001 catches a pounds reading submitted as kilograms", {
  # The D11 defect: a typical adult weight multiplied by 2.2 lands above the
  # plausible maximum, which is why that maximum is set tighter than the
  # schema's hard bound.
  forms <- fixture_forms()
  forms$screening$weight_kg <- round(80 * 2.20462, 1)
  expect_equal(nrow(validate_fixture(forms, "RNG-001")), 1)
})

test_that("RNG-001 accepts a heavy but genuinely possible patient", {
  forms <- fixture_forms()
  forms$screening$weight_kg <- 155
  expect_equal(nrow(validate_fixture(forms, "RNG-001")), 0)
})

test_that("RNG-002 fires on an impossible heart rate", {
  forms <- fixture_forms()
  forms$daily_icu$heart_rate[2] <- 400L
  findings <- validate_fixture(forms, "RNG-002")
  expect_equal(nrow(findings), 1)
  expect_equal(findings$observed_value, "400")
})

test_that("RNG-003 fires on an impossible temperature", {
  forms <- fixture_forms()
  forms$daily_icu$temperature_c[1] <- 12
  expect_equal(nrow(validate_fixture(forms, "RNG-003")), 1)
})

test_that("RNG-004 fires on an implausible creatinine", {
  forms <- fixture_forms()
  forms$screening$creatinine <- 5000
  expect_equal(nrow(validate_fixture(forms, "RNG-004")), 1)
})

test_that("RNG-005 fires on an age below the eligibility limit", {
  forms <- fixture_forms()
  forms$screening$age_years <- 12L
  findings <- validate_fixture(forms, "RNG-005")
  expect_equal(nrow(findings), 1)
  expect_equal(findings$action, "escalate")
})

test_that("RNG-006 fires on a severity score off its scale", {
  forms <- fixture_forms()
  forms$screening$severity_score <- 99L
  expect_equal(nrow(validate_fixture(forms, "RNG-006")), 1)
})

test_that("range rules do not fire on a missing value", {
  # Missingness is STR-001's job. Reporting it twice would send the site two
  # queries for one problem.
  forms <- fixture_forms()
  forms$daily_icu$heart_rate <- NA_integer_
  expect_equal(nrow(validate_fixture(forms, "RNG-002")), 0)
})

# --- Logic ------------------------------------------------------------------

test_that("LOG-001 fires on a gap in the middle of an ICU stay", {
  forms <- fixture_forms()
  forms$daily_icu <- forms$daily_icu[forms$daily_icu$icu_day != 1, ]  # remove day 1
  findings <- validate_fixture(forms, "LOG-001")
  expect_equal(nrow(findings), 1)
})

test_that("LOG-001 does not fire on consecutive days", {
  expect_equal(nrow(validate_fixture(fixture_forms(), "LOG-001")), 0)
})

test_that("LOG-002 fires when a participant is alive after their death date", {
  forms <- fixture_forms()
  forms$outcome_30d$vital_status_30d <- "dead"
  forms$outcome_30d$death_date <- FIXTURE_DATE + 1
  # Day 2 record is dated after the death date.
  findings <- validate_fixture(forms, "LOG-002")
  expect_equal(nrow(findings), 1)
  expect_equal(findings$severity, "critical")
})

test_that("LOG-002 treats the day of death itself as consistent", {
  # A participant is alive for part of the day they die, so the record dated
  # on the death date is correct and must not be flagged.
  forms <- fixture_forms()
  forms$outcome_30d$vital_status_30d <- "dead"
  forms$outcome_30d$death_date <- FIXTURE_DATE + 2   # the last daily record
  expect_equal(nrow(validate_fixture(forms, "LOG-002")), 0)
})

test_that("LOG-003 fires when vital status and death date disagree", {
  forms <- fixture_forms()
  forms$outcome_30d$vital_status_30d <- "dead"       # but death_date is NA
  expect_equal(nrow(validate_fixture(forms, "LOG-003")), 1)

  forms <- fixture_forms()
  forms$outcome_30d$death_date <- FIXTURE_DATE + 5   # but status is alive
  expect_equal(nrow(validate_fixture(forms, "LOG-003")), 1)
})

test_that("LOG-004 fires when life support is recorded for a participant not alive", {
  forms <- fixture_forms()
  forms$daily_icu$alive[2] <- 0L
  forms$daily_icu$mechanical_ventilation[2] <- 1L
  expect_equal(nrow(validate_fixture(forms, "LOG-004")), 1)
})

test_that("LOG-005 fires when an ICU record names no unit", {
  forms <- fixture_forms()
  forms$daily_icu$icu_location[1] <- NA_character_
  findings <- validate_fixture(forms, "LOG-005")
  expect_equal(nrow(findings), 1)
  expect_equal(findings$severity, "minor")
})

# --- Temporal ---------------------------------------------------------------

test_that("TMP-001 fires when discharge precedes admission", {
  forms <- fixture_forms()
  forms$outcome_30d$hospital_discharge_date <- FIXTURE_DATE - 3
  expect_equal(nrow(validate_fixture(forms, "TMP-001")), 1)
})

test_that("TMP-002 fires when death precedes randomisation", {
  forms <- fixture_forms()
  forms$outcome_30d$vital_status_30d <- "dead"
  forms$outcome_30d$death_date <- FIXTURE_DATE - 5
  expect_equal(nrow(validate_fixture(forms, "TMP-002")), 1)
})

test_that("TMP-003 fires when a record is entered before the event it describes", {
  forms <- fixture_forms()
  forms$adverse_events$entry_date <- FIXTURE_DATE - 10
  expect_equal(nrow(validate_fixture(forms, "TMP-003")), 1)
})

test_that("TMP-004 fires when an adverse event precedes randomisation", {
  forms <- fixture_forms()
  forms$adverse_events$onset_date <- FIXTURE_DATE - 4
  findings <- validate_fixture(forms, "TMP-004")
  expect_equal(nrow(findings), 1)
  expect_equal(findings$severity, "critical")
})

test_that("TMP-005 fires when randomisation precedes screening", {
  forms <- fixture_forms()
  forms$screening$screening_date <- FIXTURE_DATE + 5
  expect_true("TMP-005" %in% fired_rules(forms, "TMP-005"))
})

# --- Cross-domain -----------------------------------------------------------

#' A fixture where the participant is entered into two domains.
two_domain_fixture <- function(second_randomisation_offset_hours = 0) {
  forms <- fixture_forms()

  second_rand <- forms$randomisation
  second_rand$randomisation_id <- "RND-000002"
  second_rand$domain <- "ANTICOAG"
  second_rand$arm <- "standard_dose"
  second_rand$randomisation_datetime <- second_rand$randomisation_datetime +
    second_randomisation_offset_hours * 3600
  forms$randomisation <- rbind(forms$randomisation, second_rand)

  second_outcome <- forms$outcome_30d
  second_outcome$domain <- "ANTICOAG"
  forms$outcome_30d <- rbind(forms$outcome_30d, second_outcome)

  forms
}

test_that("a participant in two domains produces no findings when consistent", {
  expect_equal(nrow(validate_fixture(two_domain_fixture())), 0)
})

test_that("XDM-001 fires when two domains report different death dates", {
  forms <- two_domain_fixture()
  forms$outcome_30d$vital_status_30d <- "dead"
  forms$outcome_30d$death_date <- c(FIXTURE_DATE + 20, FIXTURE_DATE + 21)
  expect_true("XDM-001" %in% fired_rules(forms, "XDM-001"))
})

test_that("XDM-002 fires when two domains report different admission dates", {
  forms <- two_domain_fixture()
  forms$outcome_30d$icu_admission_date <- c(FIXTURE_DATE, FIXTURE_DATE + 2)
  expect_true("XDM-002" %in% fired_rules(forms, "XDM-002"))
})

test_that("XDM-003 fires on conflicting vital status when the windows coincide", {
  forms <- two_domain_fixture(second_randomisation_offset_hours = 0)
  forms$outcome_30d$vital_status_30d <- c("alive", "dead")
  forms$outcome_30d$death_date <- c(as.Date(NA), FIXTURE_DATE + 20)
  expect_true("XDM-003" %in% fired_rules(forms, "XDM-003"))
})

test_that("XDM-003 stays silent when the two windows genuinely end on different days", {
  # Domains anchored to randomisations two days apart have windows that end two
  # days apart, so differing 30-day status is legitimate, not a finding. This
  # is the case the rule is deliberately narrowed to avoid.
  forms <- two_domain_fixture(second_randomisation_offset_hours = 48)
  forms$outcome_30d$vital_status_30d <- c("alive", "dead")
  forms$outcome_30d$death_date <- c(as.Date(NA), FIXTURE_DATE + 20)
  expect_false("XDM-003" %in% fired_rules(forms, "XDM-003"))
})
