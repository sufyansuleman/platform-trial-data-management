# Days alive without life support at 30 days.
#
# This file has more tests than anything else in the repository, deliberately.
# The number it protects is the one an adaptive stopping decision reads: an
# error here does not produce a wrong report, it produces a wrong decision
# about whether to keep randomising patients.
#
# Written before the function, per the project's working rules.

# --- The basic shape --------------------------------------------------------

test_that("a participant free of support for the whole window scores 30", {
  result <- dawols_for(daily_records(0:29, mv = 0, vp = 0, rrt = 0))
  expect_equal(result$days_alive_without_life_support, 30)
  expect_equal(result$unknown_days, 0)
})

test_that("a participant on support every day of the window scores 0", {
  result <- dawols_for(daily_records(0:29, mv = 1))
  expect_equal(result$days_alive_without_life_support, 0)
})

test_that("each of the three supports disqualifies a day on its own", {
  expect_equal(dawols_for(daily_records(0:29, mv = 1))$days_alive_without_life_support, 0)
  expect_equal(dawols_for(daily_records(0:29, vp = 1))$days_alive_without_life_support, 0)
  expect_equal(dawols_for(daily_records(0:29, rrt = 1))$days_alive_without_life_support, 0)
})

test_that("support on some days leaves the remainder counted", {
  # Ventilated days 0-9, free days 10-29.
  daily <- daily_records(0:29, mv = c(rep(1, 10), rep(0, 20)))
  expect_equal(dawols_for(daily)$days_alive_without_life_support, 20)
})

# --- Death, at every boundary the specification names -----------------------

test_that("death within the window scores 0 regardless of prior support-free days", {
  for (death_day in c(0, 1, 29, 30)) {
    daily <- daily_records(0:min(death_day, 29))
    result <- dawols_for(daily, outcome_record(death_day = death_day))
    expect_equal(result$days_alive_without_life_support, 0,
                 info = paste("death on day", death_day))
    expect_true(result$died_within_window, info = paste("death on day", death_day))
  }
})

test_that("death on day 31 is outside the window and does not zero the score", {
  # The participant was alive throughout the 30 days being measured. Scoring
  # them 0 would import an event from outside the window into it.
  daily <- daily_records(0:29, mv = 0)
  result <- dawols_for(daily, outcome_record(death_day = 31))
  expect_equal(result$days_alive_without_life_support, 30)
  expect_false(result$died_within_window)
})

test_that("death on day 30 exactly is inside the window", {
  # The protocol asks about vital status AT 30 days, so day 30 counts as
  # within. The boundary is stated explicitly because both readings are
  # defensible and they disagree on exactly one day.
  result <- dawols_for(daily_records(0:29), outcome_record(death_day = 30))
  expect_true(result$died_within_window)
  expect_equal(result$days_alive_without_life_support, 0)
})

# --- The window boundary ----------------------------------------------------

test_that("life support starting exactly at the 30-day boundary is outside the window", {
  # Days 0-29 are the window. Support beginning on day 30 belongs to the next
  # period and must not reduce this one.
  daily <- rbind(daily_records(0:29, mv = 0), daily_records(30:35, mv = 1))
  expect_equal(dawols_for(daily)$days_alive_without_life_support, 30)
})

test_that("records beyond the window are ignored entirely", {
  daily <- rbind(daily_records(0:29, mv = 0), daily_records(30:89, mv = 1))
  result <- dawols_for(daily)
  expect_equal(result$days_alive_without_life_support, 30)
  expect_equal(result$unknown_days, 0)
})

# --- Partial days -----------------------------------------------------------

test_that("any support recorded on a day disqualifies the whole day", {
  # The daily record is a day-level flag: it says support was given at some
  # point that day, not for how long. A day with any exposure is not a day
  # free of life support. Counting fractions would invent precision the data
  # does not carry.
  daily <- daily_records(0:29, mv = 0)
  daily$vasopressors[5] <- 1L      # a single day with brief support
  expect_equal(dawols_for(daily)$days_alive_without_life_support, 29)
})

# --- Missing records: the decision that matters most ------------------------

test_that("a gap inside an ICU stay is unknown, not free of support", {
  # Days 0-4 and 10-29 recorded; days 5-9 absent with no discharge to explain
  # them. Crediting those five days would inflate the endpoint in proportion
  # to how badly a site enters data. See DEC-006.
  daily <- rbind(daily_records(0:4), daily_records(10:29))
  result <- dawols_for(daily)
  expect_equal(result$unknown_days, 5)
  expect_equal(result$days_alive_without_life_support, 25)
  expect_false(result$complete)
})

test_that("a participant with an interior gap is flagged as incomplete", {
  daily <- rbind(daily_records(0:4), daily_records(10:29))
  expect_false(dawols_for(daily)$complete)
})

test_that("a fully recorded participant is flagged as complete", {
  expect_true(dawols_for(daily_records(0:29))$complete)
})

# --- Discharge and readmission ----------------------------------------------

test_that("discharged alive on day 10 and never readmitted scores the full window", {
  # Days 11-29 have no ICU records because the participant was not in an ICU.
  # The discharge record is positive evidence that they were alive and free of
  # life support, so those days count. This is the case that distinguishes
  # "no record" from "no information".
  daily <- daily_records(0:10, mv = 0)
  result <- dawols_for(daily, outcome_record(discharge_day = 10))
  expect_equal(result$days_alive_without_life_support, 30)
  expect_equal(result$unknown_days, 0)
})

test_that("days after discharge are not credited when the participant later dies in the window", {
  daily <- daily_records(0:10, mv = 0)
  result <- dawols_for(daily, outcome_record(discharge_day = 10, death_day = 20))
  expect_equal(result$days_alive_without_life_support, 0)
})

test_that("readmission on day 20 after discharge on day 10 counts the ICU days correctly", {
  # Days 0-10 in ICU free of support, days 11-19 out of hospital, days 20-24
  # readmitted and ventilated, days 25-29 out again.
  daily <- rbind(
    daily_records(0:10, mv = 0),
    daily_records(20:24, mv = 1)
  )
  result <- dawols_for(daily, outcome_record(discharge_day = 10))
  # 11 free ICU days (0-10) + 9 out-of-hospital days (11-19)
  #  + 0 during readmission (20-24) + 5 after (25-29) = 25
  expect_equal(result$days_alive_without_life_support, 25)
})

test_that("a gap before a documented discharge is still unknown", {
  # Discharge on day 20 does not explain missing days 5-9, which fall inside
  # the stay. Only days after the discharge are explained by it.
  daily <- rbind(daily_records(0:4), daily_records(10:20))
  result <- dawols_for(daily, outcome_record(discharge_day = 20))
  expect_equal(result$unknown_days, 5)
})

# --- Transfers --------------------------------------------------------------

test_that("a transfer between ICUs mid-stay does not break the count", {
  # The unit identifier changes on day 15; the participant is one person with
  # one continuous stay and the endpoint must not notice the move.
  daily <- daily_records(0:29, mv = 0,
                         location = c(rep("DK-01-ICU1", 15), rep("DK-01-ICU2", 15)))
  result <- dawols_for(daily)
  expect_equal(result$days_alive_without_life_support, 30)
  expect_equal(result$unknown_days, 0)
})

test_that("a transfer producing two records for the transfer day is not double counted", {
  daily <- rbind(daily_records(0:15, mv = 0, location = "DK-01-ICU1"),
                 daily_records(15:29, mv = 0, location = "DK-01-ICU2"))
  result <- dawols_for(daily)
  expect_equal(result$days_alive_without_life_support, 30)
  expect_equal(result$conflicting_days, 0)   # the two records agree
})

# --- Conflicting records ----------------------------------------------------

test_that("two records for the same day that disagree make the day unknown", {
  # We cannot tell which source is right, and choosing one silently would hide
  # a data problem behind a confident-looking number. The day is unknown and
  # the conflict is counted so it can be queried.
  daily <- rbind(daily_records(0:29, mv = 0),
                 daily_records(7, mv = 1))
  result <- dawols_for(daily)
  expect_equal(result$conflicting_days, 1)
  expect_equal(result$unknown_days, 1)
  expect_equal(result$days_alive_without_life_support, 29)
  expect_false(result$complete)
})

test_that("duplicate records that agree are collapsed without complaint", {
  daily <- rbind(daily_records(0:29, mv = 0), daily_records(7, mv = 0))
  result <- dawols_for(daily)
  expect_equal(result$conflicting_days, 0)
  expect_equal(result$days_alive_without_life_support, 30)
})

# --- Alive flag -------------------------------------------------------------

test_that("a day recorded as not alive is not a day alive without life support", {
  daily <- daily_records(0:29, mv = 0)
  daily$alive[10] <- 0L
  expect_equal(dawols_for(daily)$days_alive_without_life_support, 29)
})

# --- Multi-domain anchoring -------------------------------------------------

test_that("each domain is scored against its own randomisation date", {
  # The participant enters FLUID on day 0 and ANTICOAG on day 2. The ANTICOAG
  # window therefore runs to day 31 and includes two days the FLUID window
  # does not. Using a single anchor for both would silently mis-score one.
  daily <- rbind(daily_records(0:29, mv = 0), daily_records(30:31, mv = 1))
  outcome <- rbind(outcome_record(domain = "FLUID"),
                   outcome_record(domain = "ANTICOAG"))
  randomisation <- rbind(randomisation_record(0, domain = "FLUID"),
                         randomisation_record(2, domain = "ANTICOAG"))

  result <- derive_days_alive_without_life_support(daily, outcome, randomisation)
  expect_equal(nrow(result), 2)

  fluid <- result[result$domain == "FLUID", ]
  anticoag <- result[result$domain == "ANTICOAG", ]

  expect_equal(fluid$days_alive_without_life_support, 30)   # days 0-29, all free
  # ANTICOAG window is days 2-31: days 2-29 free (28), days 30-31 ventilated.
  expect_equal(anticoag$days_alive_without_life_support, 28)
})

# --- Missing outcome data ---------------------------------------------------

test_that("a participant with no outcome record produces no endpoint row", {
  daily <- daily_records(0:29)
  result <- derive_days_alive_without_life_support(
    daily, outcome_record()[0, ], randomisation_record())
  expect_equal(nrow(result), 0)
})

test_that("the endpoint never exceeds the window length", {
  daily <- rbind(daily_records(0:29, mv = 0), daily_records(0:29, mv = 0))
  expect_lte(dawols_for(daily)$days_alive_without_life_support, 30)
})

test_that("the endpoint is never negative", {
  daily <- daily_records(0:29, mv = 1)
  expect_gte(dawols_for(daily)$days_alive_without_life_support, 0)
})

# --- Ward days: the case the original test set missed ------------------------

test_that("days between ICU discharge and hospital discharge count as free", {
  # Regression test. The first implementation credited only days after
  # HOSPITAL discharge, so a participant who left the ICU on day 2 and the
  # hospital on day 12 had days 3-11 counted as unknown. They were on a general
  # ward: alive, and not receiving life support, which is given in an ICU.
  #
  # The bug was invisible in the unit tests because every fixture discharged
  # from ICU and hospital on the same day. It surfaced only on pipeline data,
  # where it made 68% of surviving participants incomplete.
  daily <- daily_records(0:2, mv = 1)
  result <- dawols_for(daily, outcome_record(discharge_day = 12))
  expect_equal(result$unknown_days, 0)
  expect_true(result$complete)
  # Days 0-2 ventilated, days 3-29 free.
  expect_equal(result$days_alive_without_life_support, 27)
})

test_that("an interior gap is still unknown even when ward days follow", {
  # The two must not be confused: leaving the ICU explains later days, it does
  # not retrospectively explain a gap inside the stay.
  daily <- rbind(daily_records(0:2, mv = 0), daily_records(8:10, mv = 0))
  result <- dawols_for(daily, outcome_record(discharge_day = 20))
  expect_equal(result$unknown_days, 5)      # days 3-7
  expect_false(result$complete)
})
