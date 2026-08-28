# Ingest is where local conventions are undone. Every conversion it performs is
# tested here, because a silent conversion error is invisible downstream: the
# value still looks like a plausible weight, just the wrong one.

test_that("dates parse under each country's declared format", {
  expect_equal(parse_local_date("24-01-2024", "%d-%m-%Y", "test"),
               as.Date("2024-01-24"))
  expect_equal(parse_local_date("2024-01-24", "%Y-%m-%d", "test"),
               as.Date("2024-01-24"))
})

test_that("an ambiguous date is read under the declared format, not guessed", {
  # 03-04-2025 is 3 April under DD-MM-YYYY and 4 March under MM-DD-YYYY.
  # The declared format decides; nothing infers.
  expect_equal(parse_local_date("03-04-2025", "%d-%m-%Y", "test"),
               as.Date("2025-04-03"))
})

test_that("an unparseable date stops ingest rather than becoming NA", {
  expect_error(parse_local_date("31-31-2024", "%d-%m-%Y", "screening/DK-01/x"),
               "do not parse under the declared date format")
  expect_error(parse_local_date("not-a-date", "%d-%m-%Y", "screening/DK-01/x"),
               "screening/DK-01/x")
})

test_that("blank dates are missing, not malformed", {
  expect_true(is.na(parse_local_date(NA_character_, "%d-%m-%Y", "test")))
})

test_that("decimal commas are normalised", {
  expect_equal(parse_local_number("87,7", ",", "test"), 87.7)
  expect_equal(parse_local_number("87.7", ".", "test"), 87.7)
})

test_that("a non-numeric value stops ingest rather than becoming NA", {
  expect_error(parse_local_number("eighty", ".", "screening/NL-01/weight_kg"),
               "are not numeric under decimal separator")
})

test_that("pounds convert to kilograms", {
  site <- test_site("DK-07")
  expect_equal(site$weight_unit, "lb")
  converted <- convert_to_internal_units(220.462, "weight_kg", site)
  expect_equal(converted$values, 100, tolerance = 1e-4)
  expect_equal(converted$detail, "lb -> kg")
})

test_that("mg/dL converts to umol/L", {
  site <- test_site("NL-01")
  expect_equal(site$creatinine_unit, "mg/dL")
  converted <- convert_to_internal_units(1, "creatinine", site)
  expect_equal(converted$values, 88.4, tolerance = 1e-6)
})

test_that("no conversion is applied when the site already reports internal units", {
  site <- test_site("DK-01")
  expect_null(convert_to_internal_units(80, "weight_kg", site))
  expect_null(convert_to_internal_units(100, "creatinine", site))
})

test_that("conversion is driven by the declared unit, not by plausibility", {
  # A site declaring kg gets no conversion even if the value is obviously a
  # pounds reading. Catching that is the range rules' job, not ingest's --
  # this is the boundary defect D11 is built to probe.
  site <- test_site("FI-01")
  expect_equal(site$weight_unit, "kg")
  expect_null(convert_to_internal_units(185, "weight_kg", site))
})

test_that("encoding is detected from the bytes, not from configuration", {
  utf8_file <- tempfile(fileext = ".csv")
  writeLines("site_name\nSondre Hospital", utf8_file, useBytes = TRUE)
  expect_equal(detect_encoding(utf8_file), "UTF-8")

  latin1_file <- tempfile(fileext = ".csv")
  connection <- file(latin1_file, open = "wb")
  writeBin(c(charToRaw("site_name\nN"), as.raw(0xF8),
             charToRaw("rrevang\n")), connection)
  close(connection)
  expect_equal(detect_encoding(latin1_file), "latin1")
})

test_that("a Latin-1 file is transcoded to valid UTF-8 on read", {
  latin1_file <- tempfile(fileext = ".csv")
  connection <- file(latin1_file, open = "wb")
  writeBin(c(charToRaw("site_name\n\"N"), as.raw(0xF8),
             charToRaw("rrevang Hospital\"\n")), connection)
  close(connection)

  data <- read_export_file(latin1_file)
  expect_true(validUTF8(data$site_name))
  expect_equal(data$site_name, "N\u00f8rrevang Hospital")
})
