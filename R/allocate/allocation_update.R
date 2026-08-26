# ---------------------------------------------------------------------------
# Allocation updates and reconciliation.
#
# This closes the loop between whatever decides allocation probabilities and
# the randomisation system that has to apply them, which is the most
# under-appreciated failure mode in an adaptive platform trial.
#
# When new allocation probabilities are decided, they have to reach the EDC and
# take effect there. If they do not, NOTHING ERRORS. No
# exception is raised, no validation rule fires, no report looks wrong. The
# realised allocation at that site stays at whatever it was, which is a
# perfectly plausible ratio, and participants are simply randomised on the
# wrong split until somebody notices.
#
# There is only one way to catch it: compare what was SPECIFIED to be in force
# against what was REALISED, per site, per period. That comparison is the
# entire content of this file.
# ---------------------------------------------------------------------------

#' Emit a versioned, checksummed allocation update
#'
#' Models the artefact that has to travel from wherever allocation
#' probabilities are decided to the randomisation system that applies them.
#' This repository covers the data management side of the trial and does not
#' implement the interim analysis itself, so the probabilities are an input:
#' what matters here is that they arrive intact and can be checked afterwards
#' against what the sites actually did.
#'
#' Never a bare number for somebody to retype. The artefact carries the
#' probabilities, the source they came from, the date they take effect, and a
#' checksum over the content, so the value that reached the randomisation
#' system can be compared against the value that left.
#'
#' @param allocation A data frame of `domain`, `arm`, `probability`.
#' @param effective_date Date the new probabilities take effect.
#' @param source_id Identifier of whatever decided them, recorded for audit.
#' @param dir Directory to write updates into.
#' @return The update, invisibly.
emit_allocation_update <- function(allocation, effective_date,
                                   source_id = NA_character_,
                                   dir = project_path("data", "allocations")) {
  stopifnot(all(c("domain", "arm", "probability") %in% names(allocation)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  domains <- lapply(split(allocation, allocation$domain), function(rows) {
    list(
      domain = rows$domain[1],
      arms = rows$arm,
      probabilities = rows$probability
    )
  })

  update <- list(
    update_id = sprintf("ALU-%s", format(as.Date(effective_date), "%Y%m%d")),
    source_id = source_id,
    effective_date = format(as.Date(effective_date)),
    issued_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    domains = domains
  )

  # The checksum covers the content, not the file, so it survives reformatting
  # and can be recomputed by whatever system receives the update.
  update$checksum <- digest::digest(update$domains, algo = "sha256")

  path <- file.path(dir, paste0(update$update_id, ".json"))
  jsonlite::write_json(update, path, auto_unbox = TRUE, pretty = TRUE, digits = NA)

  invisible(update)
}

#' Read an allocation update and verify its checksum
#'
#' @param update_id Identifier of the update.
#' @param dir Directory holding the updates.
#' @return The update.
read_allocation_update <- function(update_id,
                                   dir = project_path("data", "allocations")) {
  path <- file.path(dir, paste0(update_id, ".json"))
  if (!file.exists(path)) {
    stop("No allocation update '", update_id, "' at ", path, call. = FALSE)
  }
  update <- jsonlite::read_json(path, simplifyVector = TRUE)

  recomputed <- digest::digest(update$domains, algo = "sha256")
  if (!identical(recomputed, update$checksum)) {
    stop("Allocation update '", update_id, "' fails its own checksum. ",
         "The probabilities may have been altered in transit.", call. = FALSE)
  }
  update
}

#' Reconcile realised allocation against what was specified
#'
#' For each site in the period, counts how many participants were allocated to
#' each arm and tests that count against the ratio that was supposed to be in
#' force, using an exact binomial test.
#'
#' A site whose update never took effect keeps randomising on the previous
#' ratio. Its realised split is a perfectly ordinary number, so nothing about
#' the site's own data looks wrong. Only the comparison against the specified
#' ratio exposes it, and only per site: pooled across all sites the one
#' deviating site is diluted by every site that applied the update correctly.
#'
#' Grouping is a power decision, not a presentation one. Testing each site
#' separately within each domain is the most specific comparison, but this
#' trial randomises only a few dozen participants per site per domain after any
#' given update, and a 10 point deviation cannot be distinguished from noise at
#' that size. Pooling a site's domains gives several times the sample and
#' detects it comfortably. Pooling is only valid when every domain specifies
#' the same probability for its favoured arm, which the function checks rather
#' than assumes.
#'
#' @param randomisation Randomisation records.
#' @param specified A data frame of `domain`, `arm`, `probability` in force.
#' @param period_start,period_end Bounds of the period to reconcile.
#' @param alpha Significance level for the per-site test.
#' @param by Grouping columns; `"site_id"` pools a site's domains.
#' @return A data frame, one row per group.
reconcile_allocation <- function(randomisation, specified,
                                 period_start, period_end, alpha = 0.01,
                                 by = "site_id") {
  period_start <- as.Date(period_start)
  period_end <- as.Date(period_end)

  in_period <- randomisation |>
    dplyr::filter(!is.na(randomisation_datetime), !is.na(arm)) |>
    dplyr::mutate(randomisation_date = as.Date(randomisation_datetime)) |>
    dplyr::filter(randomisation_date >= period_start,
                  randomisation_date <= period_end)

  if (!nrow(in_period)) {
    return(data.frame())
  }

  # The reference arm for each domain is the one the specification names first,
  # so that "realised" and "specified" are always describing the same arm.
  reference <- specified |>
    dplyr::group_by(domain) |>
    dplyr::slice_head(n = 1) |>
    dplyr::ungroup() |>
    dplyr::select(domain, reference_arm = arm, specified_probability = probability)

  joined <- in_period |> dplyr::inner_join(reference, by = "domain")

  # Pooling a site's domains is exact only when they share a specified
  # probability. Otherwise the pooled count is Poisson-binomial rather than
  # binomial and the test below would be wrong, so refuse instead of
  # approximating quietly.
  if (!"domain" %in% by) {
    probabilities <- unique(round(reference$specified_probability, 10))
    if (length(probabilities) > 1) {
      stop("Cannot pool domains: they specify different allocation ",
           "probabilities (", paste(probabilities, collapse = ", "), "). ",
           "Reconcile with by = c(\"site_id\", \"domain\").", call. = FALSE)
    }
  }

  counts <- joined |>
    dplyr::group_by(dplyr::across(dplyr::all_of(by))) |>
    dplyr::summarise(
      n = dplyr::n(),
      n_reference_arm = sum(arm == reference_arm),
      specified_probability = dplyr::first(specified_probability),
      .groups = "drop"
    ) |>
    dplyr::mutate(realised_probability = n_reference_arm / n)

  # An exact binomial test per site. Small sites produce wide intervals and are
  # correctly hard to flag, which is the behaviour we want: a site with twelve
  # participants cannot be shown to be misallocating.
  tested <- counts |>
    dplyr::rowwise() |>
    dplyr::mutate(
      p_value = stats::binom.test(n_reference_arm, n, specified_probability)$p.value,
      ci_lower = stats::binom.test(n_reference_arm, n, specified_probability)$conf.int[1],
      ci_upper = stats::binom.test(n_reference_arm, n, specified_probability)$conf.int[2]
    ) |>
    dplyr::ungroup() |>
    dplyr::mutate(
      deviation = realised_probability - specified_probability,
      flagged = p_value < alpha
    ) |>
    dplyr::arrange(p_value) |>
    as.data.frame()

  tested
}

#' Turn allocation deviations into findings
#'
#' Deviations enter the same findings table as every other data quality
#' problem, at `critical` severity, so they reach the central report through
#' the machinery that already exists rather than through a special case.
#'
#' @param reconciliation Output of [reconcile_allocation()].
#' @param sites Resolved site table.
#' @param detected_at Timestamp.
#' @return A findings data frame.
allocation_findings <- function(reconciliation, sites, detected_at = Sys.time()) {
  flagged <- reconciliation[reconciliation$flagged, ]
  if (!nrow(flagged)) return(empty_findings())

  # `domain` is absent when a site's domains were pooled for power, which is
  # the usual case. The finding then concerns the site as a whole.
  domain <- if ("domain" %in% names(flagged)) flagged$domain else NA_character_

  out <- data.frame(
    rule_id = "ALC-001",
    rule_name = "realised_allocation_matches_specified",
    severity = "critical",
    action = "escalate",
    site_id = flagged$site_id,
    participant_id = NA_character_,
    domain = domain,
    form = "randomisation",
    field = "arm",
    observed_value = sprintf("%.3f realised against %.3f specified (n = %d)",
                             flagged$realised_probability,
                             flagged$specified_probability, flagged$n),
    stringsAsFactors = FALSE
  )
  out$country <- sites$country[match(out$site_id, sites$site_id)]
  out$detected_at <- detected_at
  out$data_version <- "allocation_reconciliation"
  out$rule_set_version <- rule_set_version()
  out$finding_id <- sprintf("FND-ALC-%04d", seq_len(nrow(out)))

  out[, names(empty_findings())]
}

#' The allocation specified to be in force, from the trial configuration
#'
#' In a real trial this comes from the allocation update artefact issued by the
#' interim analysis. Here the configured update stands in for it, so that the
#' reconciliation is comparing against the specification rather than against
#' anything derived from the data it is checking.
#'
#' @param cfg Trial configuration.
#' @param defect_id Identifier of the configured allocation update.
#' @return A data frame of `domain`, `arm`, `probability`, plus the effective date.
specified_allocation <- function(cfg, defect_id = "D13") {
  ids <- vapply(cfg$defects, function(d) d$id, character(1))
  spec <- cfg$defects[[which(ids == defect_id)]]

  rows <- lapply(names(spec$arm_probabilities), function(domain) {
    probabilities <- unlist(spec$arm_probabilities[[domain]])
    # The favoured arm is listed first and is the reference for the test.
    ordered <- probabilities[order(-probabilities)]
    data.frame(domain = domain, arm = names(ordered),
               probability = as.numeric(ordered), stringsAsFactors = FALSE)
  })

  out <- do.call(rbind, rows)
  attr(out, "effective_date") <- as.Date(spec$effective_date)
  out
}
