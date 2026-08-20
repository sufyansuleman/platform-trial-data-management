# ---------------------------------------------------------------------------
# Conforming raw exports to the schema.
#
# Two rules govern this file:
#
#   1. Every transformation is LOGGED. If a value changed shape on the way in,
#      the conformance log says so, for which site and which field.
#   2. Nothing is silently coerced. A value that cannot be interpreted under an
#      explicit rule stops the pipeline. It is always better to refuse a
#      dataset than to hand an analyst a column that is quietly half NA.
# ---------------------------------------------------------------------------

#' Record a conformance event
#'
#' @param form,site_id,field What was transformed.
#' @param transformation Short machine-readable label.
#' @param detail Human-readable description of what changed.
#' @param n_values Number of values affected.
#' @return A one-row data frame.
conformance_event <- function(form, site_id, field, transformation, detail, n_values) {
  data.frame(
    form = form, site_id = site_id, field = field,
    transformation = transformation, detail = detail,
    n_values = n_values,
    stringsAsFactors = FALSE
  )
}

#' Parse dates written in a site's local format
#'
#' Fails loudly. A date that is non-blank and does not parse under the site's
#' declared format is not guessed at under some other format, because a
#' successful guess is indistinguishable from a wrong one: `03-04-2025` parses
#' happily as both 3 April and 4 March.
#'
#' @param x Character vector as read from the CSV.
#' @param date_format The site's declared format.
#' @param context Description used in the error message.
#' @return A Date vector.
parse_local_date <- function(x, date_format, context) {
  parsed <- as.Date(x, format = date_format)
  failed <- !is.na(x) & is.na(parsed)
  if (any(failed)) {
    stop("Ingest failed for ", context, ": ", sum(failed),
         " value(s) do not parse under the declared date format '", date_format,
         "'. First offending values: ",
         paste(utils::head(unique(x[failed]), 5), collapse = ", "),
         call. = FALSE)
  }
  parsed
}

#' Parse numbers written with a site's local decimal separator
#'
#' @param x Character vector as read from the CSV.
#' @param decimal_separator Either "." or ",".
#' @param context Description used in the error message.
#' @return A numeric vector.
parse_local_number <- function(x, decimal_separator, context) {
  normalised <- if (decimal_separator == ",") sub(",", ".", x, fixed = TRUE) else x
  parsed <- suppressWarnings(as.numeric(normalised))
  failed <- !is.na(x) & is.na(parsed)
  if (any(failed)) {
    stop("Ingest failed for ", context, ": ", sum(failed),
         " value(s) are not numeric under decimal separator '",
         decimal_separator, "'. First offending values: ",
         paste(utils::head(unique(x[failed]), 5), collapse = ", "),
         call. = FALSE)
  }
  parsed
}

#' Convert a value from a site's declared unit to the internal unit
#'
#' Internal storage is kg and umol/L. Conversion is driven by what the site
#' *declares*, which is the only information ingest legitimately has. A site
#' that declares kg and submits pounds is not a conversion problem -- it is a
#' data quality problem, and it is the range rules' job to catch it, not this
#' function's. Defect D11 exists to make that distinction concrete.
#'
#' @param values Numeric vector in the site's declared unit.
#' @param field Field name.
#' @param site One row of the resolved site table.
#' @return A list with the converted `values` and a `detail` string, or NULL if
#'   no conversion applied.
convert_to_internal_units <- function(values, field, site) {
  if (identical(field, "weight_kg") && identical(site$weight_unit, "lb")) {
    return(list(values = values * KG_PER_LB, detail = "lb -> kg"))
  }
  if (identical(field, "creatinine") && identical(site$creatinine_unit, "mg/dL")) {
    return(list(values = values * UMOL_PER_MG_DL_CREATININE, detail = "mg/dL -> umol/L"))
  }
  NULL
}

#' Conform one site's export of one form to the schema
#'
#' Recovers types from the schema, normalises local conventions, converts
#' units, and returns the conformance events describing everything it did.
#'
#' Assumes the file's columns are a superset of the schema's; an extra column
#' is dropped and logged, a missing one stops the pipeline.
#'
#' @param raw Character data frame from [read_export_file()].
#' @param schema Form schema.
#' @param site One row of the resolved site table.
#' @param file_encoding Encoding the file actually was, from [detect_encoding()].
#' @return A list with `data` (typed) and `events` (conformance log rows).
conform_form <- function(raw, schema, site, file_encoding) {
  form <- schema$form
  events <- list()
  columns <- vapply(schema$columns, function(c) c$name, character(1))

  missing <- setdiff(columns, names(raw))
  if (length(missing)) {
    stop("Ingest failed for ", form, " at ", site$site_id,
         ": schema column(s) absent from the export: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }

  extra <- setdiff(names(raw), columns)
  if (length(extra)) {
    events[[length(events) + 1]] <- conformance_event(
      form, site$site_id, paste(extra, collapse = ", "), "column_dropped",
      "Present in export but absent from schema.", length(extra))
  }

  # An encoding that differs from what the site declared is worth logging
  # loudly: it means the site's export configuration disagrees with its own
  # documentation, and the mangling is silent in every tool that assumes UTF-8.
  if (!identical(file_encoding, "UTF-8")) {
    events[[length(events) + 1]] <- conformance_event(
      form, site$site_id, NA_character_, "encoding_transcoded",
      paste0(file_encoding, " -> UTF-8"), nrow(raw))
  }
  if (!identical(file_encoding, site$encoding)) {
    events[[length(events) + 1]] <- conformance_event(
      form, site$site_id, NA_character_, "encoding_declaration_mismatch",
      paste0("declared ", site$encoding, ", found ", file_encoding), nrow(raw))
  }

  typed <- list()
  for (spec in schema$columns) {
    field <- spec$name
    value <- raw[[field]]
    context <- paste0(form, "/", site$site_id, "/", field)
    n_present <- sum(!is.na(value))

    typed[[field]] <- switch(
      spec$type,
      date = {
        parsed <- parse_local_date(value, site$date_format, context)
        if (n_present && site$date_format != "%Y-%m-%d") {
          events[[length(events) + 1]] <- conformance_event(
            form, site$site_id, field, "date_format_normalised",
            paste0(site$date_format, " -> ISO 8601"), n_present)
        }
        parsed
      },
      datetime = {
        date_part <- sub(" .*$", "", value)
        time_part <- sub("^\\S+ ", "", value)
        parsed_date <- parse_local_date(date_part, site$date_format, context)

        # Combine only where both halves are present. Pasting unguarded turns
        # a missing datetime into the string "NA NA", which then fails to
        # parse and would be reported as a malformed value rather than as the
        # missing value it actually is.
        parsed <- as.POSIXct(rep(NA_real_, length(value)),
                             origin = "1970-01-01", tz = "UTC")
        complete <- !is.na(parsed_date) & !is.na(time_part) & nzchar(time_part)
        if (any(complete)) {
          parsed[complete] <- as.POSIXct(
            paste(parsed_date[complete], time_part[complete]), tz = "UTC")
        }
        if (n_present && site$date_format != "%Y-%m-%d") {
          events[[length(events) + 1]] <- conformance_event(
            form, site$site_id, field, "datetime_format_normalised",
            paste0(site$date_format, " + time -> ISO 8601"), n_present)
        }
        parsed
      },
      number = {
        parsed <- parse_local_number(value, site$decimal_separator, context)
        if (n_present && site$decimal_separator != ".") {
          events[[length(events) + 1]] <- conformance_event(
            form, site$site_id, field, "decimal_separator_normalised",
            "',' -> '.'", n_present)
        }
        converted <- convert_to_internal_units(parsed, field, site)
        if (!is.null(converted)) {
          events[[length(events) + 1]] <- conformance_event(
            form, site$site_id, field, "unit_converted",
            converted$detail, n_present)
          parsed <- round(converted$values, 4)
        }
        parsed
      },
      integer = {
        parsed <- parse_local_number(value, site$decimal_separator, context)
        as.integer(round(parsed))
      },
      code = {
        # Codes whose permitted values are all numeric become integers; the
        # rest stay character. Guessing is avoided by reading the schema.
        allowed <- unlist(spec$allowed)
        numeric_codes <- !is.null(allowed) &&
          !any(is.na(suppressWarnings(as.numeric(allowed))))
        if (numeric_codes) as.integer(parse_local_number(value, ".", context)) else value
      },
      character = value,
      stop("Unknown schema type '", spec$type, "' for ", context, call. = FALSE)
    )

    n_blank <- sum(is.na(value))
    if (n_blank > 0) {
      events[[length(events) + 1]] <- conformance_event(
        form, site$site_id, field, "blank_to_na",
        "Empty string read as missing.", n_blank)
    }
  }

  list(
    data = as.data.frame(typed, stringsAsFactors = FALSE),
    events = if (length(events)) do.call(rbind, events) else NULL
  )
}

#' Ingest every raw export into conformed forms
#'
#' Reads all site files for all forms, conforms each, and stacks them. Returns
#' the conformed data alongside the full conformance log, which is itself an
#' artefact: it is the evidence of what was done to the data between the site
#' and the analysis.
#'
#' @param cfg Trial configuration.
#' @param dir Root directory of the raw exports.
#' @return A list with `forms` (named list of data frames) and `conformance_log`.
ingest_exports <- function(cfg, dir = project_path("data", "raw")) {
  sites <- resolve_sites(cfg)
  files <- list_export_files(dir)
  forms <- list()
  events <- list()

  for (i in seq_len(nrow(files))) {
    form <- files$form[i]
    site <- sites[sites$site_id == files$site_id[i], ]
    if (nrow(site) != 1) {
      stop("Export file '", files$path[i],
           "' names site '", files$site_id[i],
           "' which is not in the trial configuration.", call. = FALSE)
    }

    encoding <- detect_encoding(files$path[i])
    raw <- read_export_file(files$path[i], encoding)
    conformed <- conform_form(raw, load_schema(form), site, encoding)

    forms[[form]] <- c(forms[[form]], list(conformed$data))
    if (!is.null(conformed$events)) events[[length(events) + 1]] <- conformed$events
  }

  forms <- lapply(forms, function(parts) {
    stacked <- do.call(rbind, parts)
    rownames(stacked) <- NULL
    stacked
  })

  log <- do.call(rbind, events)
  rownames(log) <- NULL
  list(forms = forms, conformance_log = log)
}

#' Summarise the conformance log
#'
#' What a data manager actually wants to see: how many values of each kind were
#' transformed, and at how many sites.
#'
#' @param log Conformance log from [ingest_exports()].
#' @return A data frame, one row per transformation type.
conformance_summary <- function(log) {
  out <- stats::aggregate(
    cbind(values = log$n_values, rows = rep(1, nrow(log))) ~ transformation,
    data = log, FUN = sum
  )
  sites <- stats::aggregate(site_id ~ transformation, data = log,
                            FUN = function(x) length(unique(x)))
  names(sites)[2] <- "sites"
  out <- merge(out, sites, by = "transformation")
  out[order(-out$values), c("transformation", "sites", "rows", "values")]
}
