# ---------------------------------------------------------------------------
# Fixtures for data cuts and for the analysis engine that reads them.
#
# Shared rather than local to one test file: the analysis tests need the same
# cut the cut tests build, and duplicating the builder would let the two drift
# apart silently.
# ---------------------------------------------------------------------------

cut_fixture <- function() {
  forms <- fixture_forms()

  # A second participant randomised much later, so one is inside the window
  # and one is outside it for a cut taken between the two.
  late_screening <- fixture_row(
    "screening",
    screening_id = "SCR-000002", participant_id = "P-000002", site_id = "DK-02",
    screening_date = FIXTURE_DATE + 60, entry_date = FIXTURE_DATE + 61,
    age_years = 71L, weight_kg = 74, creatinine = 120, severity_score = 30L,
    enrolled = 1L
  )
  late_randomisation <- fixture_row(
    "randomisation",
    randomisation_id = "RND-000002", participant_id = "P-000002",
    site_id = "DK-02", domain = "FLUID", arm = "liberal",
    randomisation_datetime = as.POSIXct(paste(FIXTURE_DATE + 60, "12:00:00"),
                                        tz = "UTC"),
    allocation_ratio = "1:1", entry_date = FIXTURE_DATE + 61
  )
  late_outcome <- fixture_row(
    "outcome_30d",
    participant_id = "P-000002", domain = "FLUID", site_id = "DK-02",
    vital_status_30d = "alive", death_date = as.Date(NA),
    icu_admission_date = FIXTURE_DATE + 60,
    hospital_discharge_date = FIXTURE_DATE + 68,
    entry_date = FIXTURE_DATE + 92
  )
  late_daily <- do.call(rbind, lapply(60:63, function(day) {
    fixture_row(
      "daily_icu",
      record_id = sprintf("DLY-00000%02d", day), participant_id = "P-000002",
      site_id = "DK-02", icu_day = as.integer(day - 60),
      record_date = FIXTURE_DATE + day, alive = 1L, in_icu = 1L,
      mechanical_ventilation = 0L, vasopressors = 0L, renal_replacement = 0L,
      icu_location = "DK-02-ICU1", heart_rate = 90L, temperature_c = 37.2,
      entry_date = FIXTURE_DATE + day + 1
    )
  }))

  forms$screening <- rbind(forms$screening, late_screening)
  forms$randomisation <- rbind(forms$randomisation, late_randomisation)
  forms$outcome_30d <- rbind(forms$outcome_30d, late_outcome)
  forms$daily_icu <- rbind(forms$daily_icu, late_daily)

  forms
}

cut_inputs <- function(forms = cut_fixture()) {
  endpoint <- derive_days_alive_without_life_support(
    forms$daily_icu, forms$outcome_30d, forms$randomisation)
  findings <- validate_fixture(forms)
  list(forms = forms, endpoint = endpoint, findings = findings)
}

# A throwaway directory per test, so cuts never touch data/cuts/.
temp_cut_dir <- function() {
  path <- file.path(tempdir(), paste0("cuts-", as.integer(runif(1, 1, 1e9))))
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  path
}

analysis_cut <- function() {
  inputs <- cut_inputs()
  dir <- temp_cut_dir()
  manifest <- make_cut(FIXTURE_DATE + 100, inputs$forms, inputs$findings,
                       inputs$endpoint, dir = dir)
  list(dir = dir, cut_id = manifest$cut_id)
}
