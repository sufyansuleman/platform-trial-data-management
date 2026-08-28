# ---------------------------------------------------------------------------
# Data cuts: frozen, verifiable, reproducible datasets.
#
# Built to the contract in docs/data_cut_sop.md, which was written first so
# that this code has something to be held to rather than defining correctness
# by whatever it happens to produce.
#
# The guarantee: given a cut ID, the exact dataset a committee saw can be
# regenerated and proven identical. That holds because the pipeline is
# deterministic from a seed, and because the manifest records every version the
# output depends on.
# ---------------------------------------------------------------------------

CUT_FORMS <- c("screening", "randomisation", "daily_icu", "outcome_30d",
               "adverse_events")

#' Identifier for a cut taken as of a given date
#'
#' @param as_of_date The cut's as-of date.
#' @return A character cut ID.
cut_id_for <- function(as_of_date) {
  paste0("CUT-", format(as.Date(as_of_date), "%Y%m%d"))
}

#' Which participant-domain records have completed follow-up
#'
#' A record enters the cut when its 30-day window has closed on or before the
#' as-of date, and when it has a randomisation date and time to anchor that
#' window to.
#'
#' Records are included **whether or not their data is complete**. Excluding a
#' participant because their daily records are missing would select the
#' analysis population on data quality, which correlates with site, which
#' correlates with everything else. They are included with an incomplete
#' endpoint and an explicit count of unknown days.
#'
#' @param forms Conformed forms.
#' @param as_of_date The cut's as-of date.
#' @param window_days Length of the follow-up window.
#' @return A data frame of `participant_id` and `domain` eligible for the cut.
completed_follow_up <- function(forms, as_of_date, window_days = 30) {
  as_of_date <- as.Date(as_of_date)

  forms$randomisation |>
    dplyr::filter(!is.na(randomisation_datetime)) |>
    dplyr::group_by(participant_id, domain) |>
    dplyr::summarise(
      domain_randomisation_date = as.Date(min_or_na(randomisation_datetime)),
      .groups = "drop"
    ) |>
    dplyr::filter(domain_randomisation_date <= as_of_date - window_days) |>
    dplyr::select(participant_id, domain) |>
    as.data.frame()
}

#' SHA-256 of a file
#'
#' Computed from the file as written, never from the in-memory object, because
#' the file is what a later reader verifies.
#'
#' @param path Path to a file.
#' @return A 64-character hash.
file_sha256 <- function(path) {
  digest::digest(path, algo = "sha256", file = TRUE)
}

#' Record the provenance a cut needs to be reproducible
#'
#' A dataset without the code version that produced it can be inspected but not
#' regenerated.
#'
#' @param cfg Trial configuration.
#' @return A named list of provenance fields.
cut_provenance <- function(cfg) {
  git_sha <- tryCatch(
    trimws(system2("git", c("rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE)),
    error = function(e) NA_character_,
    warning = function(w) NA_character_
  )
  git_dirty <- tryCatch(
    length(system2("git", c("status", "--porcelain"), stdout = TRUE,
                   stderr = FALSE)) > 0,
    error = function(e) NA
  )

  packages <- c("targets", "dplyr", "arrow", "yaml", "digest", "tidyr")
  versions <- vapply(packages, function(p) {
    tryCatch(as.character(utils::packageVersion(p)),
             error = function(e) NA_character_)
  }, character(1))

  list(
    git_commit = if (length(git_sha)) git_sha[1] else NA_character_,
    git_working_tree_clean = !isTRUE(git_dirty),
    r_version = R.version.string,
    package_versions = as.list(versions),
    rule_set_version = rule_set_version(),
    trial_config_sha256 = file_sha256(project_path("config", "trial.yml")),
    renv_lock_sha256 = tryCatch(file_sha256(project_path("renv.lock")),
                                error = function(e) NA_character_),
    trial_seed = cfg$trial$seed
  )
}

#' Produce a frozen data cut
#'
#' Follows docs/data_cut_sop.md section 5. The order of the final steps is not
#' interchangeable: files are written, then hashed from disk, then recorded in
#' the manifest.
#'
#' @param as_of_date Cut date. Participants whose 30-day window closed on or
#'   before this date are included.
#' @param forms Conformed forms.
#' @param findings Findings table at the moment of the cut.
#' @param endpoint Derived endpoint table.
#' @param cfg Trial configuration.
#' @param dir Directory to write cuts into.
#' @param created_at Creation timestamp; overridable so that reproduction can
#'   compare data files without the timestamp differing.
#' @return The manifest, invisibly.
make_cut <- function(as_of_date, forms, findings, endpoint,
                     cfg = load_trial_config(),
                     dir = project_path("data", "cuts"),
                     created_at = Sys.time()) {
  as_of_date <- as.Date(as_of_date)
  cut_id <- cut_id_for(as_of_date)
  cut_dir <- file.path(dir, cut_id)

  # A cut is immutable. Rebuilding one replaces it wholesale rather than
  # merging into whatever was there before.
  unlink(cut_dir, recursive = TRUE)
  dir.create(cut_dir, recursive = TRUE, showWarnings = FALSE)

  included <- completed_follow_up(forms, as_of_date,
                                  cfg$clinical$outcome_window_days)
  if (!nrow(included)) {
    stop("No participant has completed follow-up as of ", format(as_of_date),
         ". The earliest possible cut date is ",
         format(min(as.Date(forms$randomisation$randomisation_datetime),
                    na.rm = TRUE) + cfg$clinical$outcome_window_days), ".",
         call. = FALSE)
  }
  participants <- unique(included$participant_id)

  # -- Filter each form to the cut -----------------------------------------
  frozen <- list()
  for (form in CUT_FORMS) {
    data <- forms[[form]]
    keep <- data$participant_id %in% participants

    # outcome_30d and randomisation are per participant-domain, so they are
    # filtered on the pair: a participant may have completed follow-up in one
    # domain while still inside the window in another.
    if ("domain" %in% names(data)) {
      pairs <- paste(data$participant_id, data$domain)
      keep <- keep & pairs %in% paste(included$participant_id, included$domain)
    }
    frozen[[form]] <- data[keep & !is.na(keep), ]
  }

  frozen$endpoint <- endpoint[
    paste(endpoint$participant_id, endpoint$domain) %in%
      paste(included$participant_id, included$domain), ]
  frozen$findings <- findings[findings$participant_id %in% participants |
                                is.na(findings$participant_id), ]

  # -- Write, then hash what was written ------------------------------------
  written <- character()
  for (name in names(frozen)) {
    path <- file.path(cut_dir, paste0(name, ".parquet"))
    arrow::write_parquet(frozen[[name]], path)
    written <- c(written, path)
  }

  hashes <- vapply(written, file_sha256, character(1))
  names(hashes) <- basename(written)

  # -- Manifest -------------------------------------------------------------
  manifest <- list(
    cut_id = cut_id,
    as_of_date = format(as_of_date),
    created_at = format(as.POSIXct(created_at, tz = "UTC"),
                        "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    window_days = cfg$clinical$outcome_window_days,

    contents = list(
      participants = length(participants),
      participant_domain_records = nrow(included),
      rows_by_file = as.list(vapply(frozen, nrow, integer(1))),
      participants_by_domain = as.list(table(included$domain)),
      participants_by_site = as.list(table(
        forms$randomisation$site_id[
          forms$randomisation$participant_id %in% participants]))
    ),

    data_quality = list(
      findings_by_severity = as.list(table(frozen$findings$severity)),
      endpoint_complete = sum(frozen$endpoint$complete, na.rm = TRUE),
      endpoint_incomplete = sum(!frozen$endpoint$complete, na.rm = TRUE),
      endpoint_not_evaluable = sum(
        is.na(frozen$endpoint$days_alive_without_life_support)),
      total_unknown_days = sum(frozen$endpoint$unknown_days, na.rm = TRUE)
    ),

    provenance = cut_provenance(cfg),
    files = as.list(hashes)
  )

  jsonlite::write_json(manifest, file.path(cut_dir, "manifest.json"),
                       auto_unbox = TRUE, pretty = TRUE, digits = NA)

  invisible(manifest)
}

#' Read a cut's manifest
#'
#' @param cut_id Cut identifier.
#' @param dir Directory holding the cuts.
#' @return The manifest as a list.
read_cut_manifest <- function(cut_id, dir = project_path("data", "cuts")) {
  path <- file.path(dir, cut_id, "manifest.json")
  if (!file.exists(path)) {
    stop("No manifest for cut '", cut_id, "' at ", path, call. = FALSE)
  }
  jsonlite::read_json(path, simplifyVector = TRUE)
}

#' Load a cut's data
#'
#' Verifies the cut before returning anything, so no caller can accidentally
#' analyse a modified cut.
#'
#' @param cut_id Cut identifier.
#' @param dir Directory holding the cuts.
#' @param verify Whether to verify hashes first. Leave TRUE.
#' @return A named list of data frames.
read_cut <- function(cut_id, dir = project_path("data", "cuts"), verify = TRUE) {
  if (verify) {
    check <- verify_cut(cut_id, dir)
    if (!check$verified) {
      stop("Cut '", cut_id, "' failed verification. Altered file(s): ",
           paste(check$mismatched, collapse = ", "),
           "\nThis cut must not be used for analysis.", call. = FALSE)
    }
  }
  cut_dir <- file.path(dir, cut_id)
  files <- list.files(cut_dir, pattern = glob2rx("*.parquet"), full.names = TRUE)
  out <- lapply(files, function(f) as.data.frame(arrow::read_parquet(f)))
  names(out) <- tools::file_path_sans_ext(basename(files))
  out
}

#' Verify that a cut has not been altered since it was frozen
#'
#' Recomputes the SHA-256 of every file and compares against the manifest. Any
#' disagreement means the cut has been altered and must not be used: an
#' analysis on a silently modified cut is worse than no analysis, because it
#' carries the authority of a frozen dataset without the substance of one.
#'
#' @param cut_id Cut identifier.
#' @param dir Directory holding the cuts.
#' @return A list with `verified`, `mismatched` and `missing`.
verify_cut <- function(cut_id, dir = project_path("data", "cuts")) {
  manifest <- read_cut_manifest(cut_id, dir)
  cut_dir <- file.path(dir, cut_id)
  recorded <- unlist(manifest$files)

  missing <- character()
  mismatched <- character()

  for (file_name in names(recorded)) {
    path <- file.path(cut_dir, file_name)
    if (!file.exists(path)) {
      missing <- c(missing, file_name)
      next
    }
    if (!identical(file_sha256(path), recorded[[file_name]])) {
      mismatched <- c(mismatched, file_name)
    }
  }

  # A file present in the cut but absent from the manifest is also a change.
  present <- setdiff(basename(list.files(cut_dir, pattern = glob2rx("*.parquet"),
                                         full.names = TRUE)),
                     names(recorded))

  list(
    cut_id = cut_id,
    verified = length(missing) == 0 && length(mismatched) == 0 &&
      length(present) == 0,
    mismatched = mismatched,
    missing = missing,
    unexpected = present
  )
}

#' Regenerate a historical cut and prove it identical
#'
#' Rebuilds the cut from the same inputs and asserts that every file hashes to
#' the value recorded in the original manifest.
#'
#' The creation timestamp is deliberately taken from the original manifest.
#' Reproduction asks whether the same inputs give the same data, not whether
#' the clock has moved.
#'
#' @param cut_id Cut identifier.
#' @param forms,findings,endpoint The same inputs the cut was built from.
#' @param cfg Trial configuration.
#' @param dir Directory holding the cuts.
#' @return A list with `reproduced` and the per-file comparison.
reproduce_cut <- function(cut_id, forms, findings, endpoint,
                          cfg = load_trial_config(),
                          dir = project_path("data", "cuts")) {
  original <- read_cut_manifest(cut_id, dir)

  scratch <- file.path(tempdir(), paste0("reproduce-", cut_id))
  unlink(scratch, recursive = TRUE)
  dir.create(scratch, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)

  rebuilt <- make_cut(
    as_of_date = as.Date(original$as_of_date),
    forms = forms, findings = findings, endpoint = endpoint,
    cfg = cfg, dir = scratch,
    created_at = as.POSIXct(original$created_at, format = "%Y-%m-%dT%H:%M:%SZ",
                            tz = "UTC")
  )

  original_files <- unlist(original$files)
  rebuilt_files <- unlist(rebuilt$files)

  comparison <- data.frame(
    file = names(original_files),
    original_sha256 = as.character(original_files),
    rebuilt_sha256 = as.character(rebuilt_files[names(original_files)]),
    stringsAsFactors = FALSE
  )
  comparison$identical <- comparison$original_sha256 == comparison$rebuilt_sha256

  list(
    cut_id = cut_id,
    reproduced = all(comparison$identical, na.rm = TRUE) &&
      !anyNA(comparison$rebuilt_sha256),
    comparison = comparison
  )
}

#' List the cuts that exist
#'
#' @param dir Directory holding the cuts.
#' @return A data frame, one row per cut.
list_cuts <- function(dir = project_path("data", "cuts")) {
  ids <- list.dirs(dir, recursive = FALSE, full.names = FALSE)
  ids <- ids[file.exists(file.path(dir, ids, "manifest.json"))]
  if (!length(ids)) {
    return(data.frame(cut_id = character(), as_of_date = character(),
                      created_at = character(), participants = integer(),
                      stringsAsFactors = FALSE))
  }
  rows <- lapply(ids, function(id) {
    manifest <- read_cut_manifest(id, dir)
    data.frame(cut_id = manifest$cut_id, as_of_date = manifest$as_of_date,
               created_at = manifest$created_at,
               participants = manifest$contents$participants,
               records = manifest$contents$participant_domain_records,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
