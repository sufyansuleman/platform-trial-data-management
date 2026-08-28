# ---------------------------------------------------------------------------
# Shared helpers used across simulate/, ingest/, validate/, derive/ and cut/.
# ---------------------------------------------------------------------------

#' Locate the project root
#'
#' Walks up from the working directory looking for `_targets.R`. Every path
#' the pipeline reads from configuration is resolved against this rather than
#' against the working directory, so the same call works from the project root,
#' from `tests/testthat/`, and from a Quarto document rendering in its own
#' directory. Relying on the working directory instead means the code works
#' until the first time something calls it from somewhere else.
#'
#' @param start Directory to begin the search from.
#' @return Absolute path to the project root.
find_project_root <- function(start = getwd()) {
  path <- normalizePath(start, winslash = "/", mustWork = TRUE)
  while (!file.exists(file.path(path, "_targets.R"))) {
    parent <- dirname(path)
    if (identical(parent, path)) {
      stop("Could not locate the project root (no _targets.R found above '",
           start, "').", call. = FALSE)
    }
    path <- parent
  }
  path
}

#' Build a path relative to the project root
#'
#' @param ... Path components, as for [file.path()].
#' @return An absolute path.
project_path <- function(...) file.path(find_project_root(), ...)

#' Load the trial configuration
#'
#' Reads `config/trial.yml` and returns it as a nested list. Assumes the file
#' exists and is valid YAML; a malformed config should fail loudly here rather
#' than produce a half-built dataset downstream.
#'
#' @param path Path to the configuration file.
#' @return A nested list mirroring the YAML structure.
load_trial_config <- function(path = project_path("config", "trial.yml")) {
  stopifnot(file.exists(path))
  yaml::read_yaml(path)
}

#' Load a form schema
#'
#' @param form Form name, e.g. "daily_icu".
#' @param dir Directory holding the schema YAML files.
#' @return A list with `form`, `key` and `columns`.
load_schema <- function(form, dir = project_path("config", "schema")) {
  path <- file.path(dir, paste0(form, ".yml"))
  stopifnot(file.exists(path))
  yaml::read_yaml(path)
}

#' Names of all forms defined by the schema directory
#'
#' @param dir Directory holding the schema YAML files.
#' @return Character vector of form names.
schema_forms <- function(dir = project_path("config", "schema")) {
  tools::file_path_sans_ext(basename(list.files(dir, pattern = glob2rx("*.yml"))))
}

#' Resolve the site table, applying country defaults
#'
#' Each site inherits its country's local conventions (date format, decimal
#' separator, units, encoding) unless it overrides them explicitly. Assumes
#' every site names a country that exists in the config.
#'
#' @param cfg Trial configuration from [load_trial_config()].
#' @return A data frame, one row per site, with conventions resolved.
resolve_sites <- function(cfg) {
  conventions <- c("date_format", "decimal_separator", "weight_unit",
                   "creatinine_unit", "encoding")

  rows <- lapply(cfg$sites, function(site) {
    country <- cfg$countries[[site$country]]
    stopifnot(!is.null(country))

    resolved <- lapply(conventions, function(key) {
      if (!is.null(site[[key]])) site[[key]] else country[[key]]
    })
    names(resolved) <- conventions

    data.frame(
      site_id         = site$id,
      site_name       = site$name,
      country         = site$country,
      country_name    = country$name,
      initiation_date = as.Date(site$initiation_date),
      capacity        = site$capacity,
      stringsAsFactors = FALSE
    ) |> cbind(as.data.frame(resolved, stringsAsFactors = FALSE))
  })

  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

#' Build a lookup of public holidays by country
#'
#' @param cfg Trial configuration.
#' @return A named list of Date vectors, one element per country.
holiday_calendar <- function(cfg) {
  lapply(cfg$holidays, function(dates) as.Date(unlist(dates)))
}

#' Test whether dates fall near a public holiday in a given country
#'
#' "Near" means within `window` days either side, which is how holiday effects
#' actually behave: entry backlogs build before and clear after the day itself.
#'
#' @param dates Vector of Dates to test.
#' @param country Two-letter country code.
#' @param calendar Holiday calendar from [holiday_calendar()].
#' @param window Number of days either side that still counts as "near".
#' @return Logical vector, the same length as `dates`.
near_holiday <- function(dates, country, calendar, window) {
  holidays <- calendar[[country]]
  if (is.null(holidays)) return(rep(FALSE, length(dates)))
  vapply(dates, function(d) any(abs(as.numeric(d - holidays)) <= window),
         logical(1))
}

#' Draw from a truncated normal distribution
#'
#' Values outside `[min, max]` are clamped rather than resampled, which keeps
#' the draw count deterministic for a given seed. Assumes the bounds are wide
#' enough that clamping is rare.
#'
#' @param n Number of draws.
#' @param mean,sd Distribution parameters.
#' @param min,max Bounds to clamp to.
#' @return Numeric vector of length `n`.
rnorm_bounded <- function(n, mean, sd, min, max) {
  pmin(pmax(stats::rnorm(n, mean, sd), min), max)
}

#' Convert a linear predictor to a probability
#'
#' @param x Numeric vector on the log-odds scale.
#' @return Numeric vector of probabilities.
inv_logit <- function(x) 1 / (1 + exp(-x))

#' Minimum of a vector, or NA when it holds no usable value
#'
#' `min()` on an all-missing vector warns and returns `Inf`, which then
#' propagates silently into date comparisons as a value nothing can exceed.
#' Returning NA instead keeps "we do not know" distinct from "infinitely far
#' in the future", which for a date of death is not a subtle difference.
#'
#' @param x A vector.
#' @return The minimum, or NA of the same type as `x`.
min_or_na <- function(x) {
  usable <- x[!is.na(x)]
  if (!length(usable)) return(x[NA_integer_][1])
  min(usable)
}
