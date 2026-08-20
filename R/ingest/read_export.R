# ---------------------------------------------------------------------------
# Reading the raw EDC exports.
#
# Everything is read as character. Nothing is coerced here: type recovery is
# conform.R's job, and doing it in one place means every coercion can be
# logged. R's own CSV type guessing is switched off deliberately -- a column
# that guesses "integer" on one site's file and "character" on another's is the
# quiet start of a very bad afternoon.
# ---------------------------------------------------------------------------

#' Detect the character encoding of a file
#'
#' Determined from the bytes, not from what the configuration claims the site
#' emits. A site's declared encoding is a statement of intent; the bytes are
#' the fact, and when they disagree it is the declaration that is wrong.
#'
#' Only the two encodings this pipeline expects are distinguished. Anything
#' that is not valid UTF-8 is assumed to be Latin-1, which is the realistic
#' failure mode for Nordic and Dutch site labels.
#'
#' @param path Path to a CSV file.
#' @return Either "UTF-8" or "latin1".
detect_encoding <- function(path) {
  bytes <- readBin(path, "raw", file.info(path)$size)
  text <- rawToChar(bytes)
  if (validUTF8(text)) "UTF-8" else "latin1"
}

#' Read one raw export file as character columns
#'
#' Reads the file in whatever encoding its bytes actually are, transcoding to
#' UTF-8 on the way in. Every column comes back as character with blanks as
#' `NA`, ready for [conform_form()] to type.
#'
#' Assumes the file has a header row and is comma separated with quoted
#' fields, which is what [export_edc()] writes.
#'
#' @param path Path to a CSV file.
#' @param encoding Encoding to read as, from [detect_encoding()].
#' @return A data frame of character columns.
read_export_file <- function(path, encoding = detect_encoding(path)) {
  data <- utils::read.csv(
    path,
    colClasses = "character",
    na.strings = "",
    check.names = FALSE,
    fileEncoding = encoding
  )
  # Guarantee UTF-8 downstream regardless of what came off disk.
  for (column in names(data)) {
    data[[column]] <- enc2utf8(as.character(data[[column]]))
  }
  data
}

#' List every raw export file with the site and form it belongs to
#'
#' Assumes the layout written by [export_edc()]: `<dir>/<form>/<site_id>.csv`.
#'
#' @param dir Root directory of the raw exports.
#' @return A data frame with `form`, `site_id` and `path`.
list_export_files <- function(dir = project_path("data", "raw")) {
  forms <- schema_forms()
  rows <- lapply(forms, function(form) {
    form_dir <- file.path(dir, form)
    if (!dir.exists(form_dir)) return(NULL)
    paths <- list.files(form_dir, pattern = glob2rx("*.csv"), full.names = TRUE)
    if (!length(paths)) return(NULL)
    data.frame(
      form = form,
      site_id = tools::file_path_sans_ext(basename(paths)),
      path = paths,
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  if (is.null(out)) {
    stop("No raw export files found under '", dir,
         "'. Run the simulation first: targets::tar_make()")
  }
  rownames(out) <- NULL
  out
}
