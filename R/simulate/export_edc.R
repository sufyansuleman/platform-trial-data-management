# ---------------------------------------------------------------------------
# Simulated EDC export.
#
# This is the boundary where the data stops being tidy. Each site exports in
# its own local conventions: its country's date format and decimal separator,
# its declared units, and its character encoding. One site emits Latin-1.
#
# Everything this file does deliberately, the ingest layer has to undo -- and
# has to log that it undid it.
#
# One CSV per site per form, because conventions are a property of the site.
# A single combined file could not hold two date formats at once.
# ---------------------------------------------------------------------------

# Conversions applied when a site's declared unit differs from the internal
# storage unit. Internal storage is kg and umol/L throughout.
KG_PER_LB <- 0.45359237
UMOL_PER_MG_DL_CREATININE <- 88.4

#' Format dates in a site's local convention
#'
#' @param x Vector of Dates (or NA).
#' @param date_format A strptime-style format string from config.
#' @return Character vector, empty string for NA.
format_local_date <- function(x, date_format) {
  out <- format(as.Date(x), date_format)
  ifelse(is.na(out), "", out)
}

#' Format numbers in a site's local convention
#'
#' Applies the site's decimal separator. Assumes the caller has already
#' converted the value into the site's declared unit.
#'
#' @param x Numeric vector.
#' @param decimal_separator Either "." or ",".
#' @param digits Number of decimal places to retain.
#' @return Character vector, empty string for NA.
format_local_number <- function(x, decimal_separator, digits = 1) {
  out <- formatC(x, format = "f", digits = digits)
  out[is.na(x)] <- ""
  if (decimal_separator == ",") out <- sub(".", ",", out, fixed = TRUE)
  out
}

#' Convert internal values into a site's declared units
#'
#' Weight is stored internally in kg and creatinine in umol/L. A site declaring
#' lb or mg/dL exports the converted value; ingest is responsible for
#' converting it back and logging that it did so.
#'
#' @param data A form subset for one site.
#' @param site One row of the resolved site table.
#' @return `data` with unit columns converted in place.
apply_local_units <- function(data, site) {
  if ("weight_kg" %in% names(data) && site$weight_unit == "lb") {
    data$weight_kg <- data$weight_kg / KG_PER_LB
  }
  if ("creatinine" %in% names(data) && site$creatinine_unit == "mg/dL") {
    data$creatinine <- data$creatinine / UMOL_PER_MG_DL_CREATININE
  }
  data
}

#' Render one form for one site into export-ready character columns
#'
#' Every column becomes character, because a CSV has no types. That is the
#' whole point of the exercise: ingest must recover the types from the schema
#' and the site's declared conventions, not by guessing.
#'
#' @param data A form subset for one site.
#' @param site One row of the resolved site table.
#' @param schema The form schema.
#' @return A data frame of character columns.
render_export <- function(data, site, schema) {
  data <- apply_local_units(data, site)
  types <- vapply(schema$columns, function(c) c$type, character(1))
  names(types) <- vapply(schema$columns, function(c) c$name, character(1))

  out <- lapply(names(data), function(column) {
    type <- types[[column]]
    value <- data[[column]]

    if (identical(type, "date")) {
      format_local_date(value, site$date_format)
    } else if (identical(type, "datetime")) {
      # Date part in the local format, time appended in ISO style. A missing
      # datetime must export as a genuinely empty field: pasting the parts
      # unguarded yields the string " NA", which is not blank and not a
      # datetime, and would stop ingest.
      rendered <- paste(format_local_date(as.Date(value), site$date_format),
                        format(value, "%H:%M:%S"))
      ifelse(is.na(value), "", rendered)
    } else if (identical(type, "number")) {
      digits <- if (identical(column, "creatinine") &&
                    identical(site$creatinine_unit, "mg/dL")) 2 else 1
      format_local_number(value, site$decimal_separator, digits)
    } else {
      out_chr <- as.character(value)
      ifelse(is.na(out_chr), "", out_chr)
    }
  })
  names(out) <- names(data)
  as.data.frame(out, stringsAsFactors = FALSE)
}

#' Write the simulated EDC exports to disk
#'
#' Produces `data/raw/<form>/<site_id>.csv`. Sites declaring a non-UTF-8
#' encoding get their file written in that encoding, which mangles the Nordic
#' characters in the denormalised `site_name` column exactly as a real
#' misconfigured export would.
#'
#' Assumes `dir` is writable and safe to clear; it is gitignored by design.
#'
#' @param forms Corrupted forms from [inject_defects()].
#' @param cfg Trial configuration.
#' @param dir Output directory for the raw exports.
#' @return A data frame describing every file written.
export_edc <- function(forms, cfg, dir = "data/raw") {
  sites <- resolve_sites(cfg)
  form_names <- setdiff(names(forms), "course")
  written <- list()

  for (form in form_names) {
    schema <- load_schema(form)
    data <- forms[[form]]

    # Denormalise the site label into the export, as EDC exports do.
    data$site_name <- sites$site_name[match(data$site_id, sites$site_id)]

    form_dir <- file.path(dir, form)
    dir.create(form_dir, recursive = TRUE, showWarnings = FALSE)

    for (i in seq_len(nrow(sites))) {
      site <- sites[i, ]
      subset_rows <- data[data$site_id == site$site_id, ]
      if (nrow(subset_rows) == 0) next

      rendered <- render_export(subset_rows, site, schema)
      path <- file.path(form_dir, paste0(site$site_id, ".csv"))

      connection <- file(path, open = "w", encoding = site$encoding)
      utils::write.csv(rendered, connection, row.names = FALSE, quote = TRUE,
                       fileEncoding = site$encoding)
      close(connection)

      written[[paste(form, site$site_id)]] <- data.frame(
        form = form, site_id = site$site_id, path = path,
        rows = nrow(rendered), encoding = site$encoding,
        date_format = site$date_format,
        decimal_separator = site$decimal_separator,
        stringsAsFactors = FALSE
      )
    }
  }

  out <- do.call(rbind, written)
  rownames(out) <- NULL
  out
}
