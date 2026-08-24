# ---------------------------------------------------------------------------
# The interim analysis engine.
#
# run_adaptive_analysis() takes a CUT ID and nothing else. It verifies the
# cut's manifest before touching the data and refuses to proceed if
# verification fails: an analysis on a silently modified cut is worse than no
# analysis, because it carries the authority of a frozen dataset without the
# substance of one.
#
# Every number the engine applies comes from configuration, not from a literal
# in this file. The priors are in config/priors.yml and the thresholds in
# config/decision_rules.yml, both pre-specified and committed before this code
# existed. Every analysis stamps the versions it used.
#
# Governed by docs/statistical_analysis_plan.md.
# ---------------------------------------------------------------------------

#' Version of the statistical analysis plan this engine implements.
#'
#' Declared once and stamped onto every analysis record. Held here rather than
#' written as a literal at the point of use so that a plan amendment updates it
#' in exactly one place and cannot leave a record claiming the wrong version.
SAP_VERSION <- "1.1"

#' Assemble the analysis dataset for one domain
#'
#' Joins the frozen endpoint to the arm each participant was allocated to. The
#' allocation comes from the randomisation record, not from anything about what
#' the participant actually received, because the primary analysis is by
#' intention to treat.
#'
#' @param cut_data Data read from a verified cut.
#' @param domain Domain to assemble.
#' @return A data frame with one row per participant-domain record.
analysis_dataset <- function(cut_data, domain) {
  allocations <- cut_data$randomisation |>
    dplyr::filter(domain == !!domain, !is.na(randomisation_datetime)) |>
    dplyr::group_by(participant_id, domain) |>
    dplyr::slice_min(randomisation_datetime, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::select(participant_id, domain, arm)

  # Vital status is joined one-to-one. Duplicate identifiers exist in this data
  # by design (defect D06 issues the same participant id at two sites), and an
  # unguarded join would silently duplicate those participants in the analysis,
  # giving them double weight in the comparison. Reducing to one row per
  # participant-domain first makes the join safe, and `relationship` makes the
  # assumption fail loudly if it ever stops holding.
  vital_status <- cut_data$outcome_30d |>
    dplyr::filter(domain == !!domain) |>
    dplyr::group_by(participant_id, domain) |>
    dplyr::slice_head(n = 1) |>
    dplyr::ungroup() |>
    dplyr::select(participant_id, domain, vital_status_30d)

  cut_data$endpoint |>
    dplyr::filter(domain == !!domain) |>
    dplyr::inner_join(allocations, by = c("participant_id", "domain"),
                      relationship = "many-to-one") |>
    dplyr::left_join(vital_status, by = c("participant_id", "domain"),
                     relationship = "many-to-one") |>
    as.data.frame()
}

#' Analyse one domain
#'
#' @param data Output of [analysis_dataset()].
#' @param priors Priors from [load_priors()].
#' @param rules Decision rules from [load_decision_rules()].
#' @param population Label recorded on the result, e.g. "itt".
#' @return A list of results for the domain.
analyse_domain <- function(data, priors, rules, population = "itt") {
  # A record with no recorded allocation cannot be analysed by intention to
  # treat: there is no arm to attribute it to. It is dropped from the
  # comparison and counted, never silently absorbed. Leaving the NA in place
  # propagates it through every sum and count in the result.
  no_allocation <- sum(is.na(data$arm))
  data <- data[!is.na(data$arm), ]

  arms <- sort(unique(data$arm))
  if (length(arms) != 2) {
    stop("Expected exactly two arms, found ", length(arms), ": ",
         paste(arms, collapse = ", "), call. = FALSE)
  }

  outcome <- data$days_alive_without_life_support
  values_a <- outcome[data$arm == arms[1]]
  values_b <- outcome[data$arm == arms[2]]

  # The observation standard deviation is estimated from the pooled data and
  # held fixed, as the analysis plan specifies. The configured value is the
  # fallback for a cut too small to estimate it from.
  specification <- priors$primary_outcome
  pooled <- outcome[!is.na(outcome)]
  sigma <- if (isTRUE(specification$outcome_sd$estimate_from_data) &&
               length(pooled) > 2) {
    stats::sd(pooled)
  } else {
    specification$outcome_sd$value
  }

  posterior_a <- normal_posterior(values_a, specification$arm_mean_prior$mean,
                                  specification$arm_mean_prior$sd, sigma)
  posterior_b <- normal_posterior(values_b, specification$arm_mean_prior$mean,
                                  specification$arm_mean_prior$sd, sigma)

  comparison <- normal_difference(posterior_a, posterior_b,
                                  rules$thresholds$equivalence_margin_days,
                                  higher_is_better = TRUE)
  decision <- apply_decision_rules(comparison, rules)
  allocation <- update_allocation(comparison$probability_a_better, rules)

  # Secondary outcome: 30-day mortality. Reported, never decisive (DEC-020).
  deaths_a <- sum(data$vital_status_30d[data$arm == arms[1]] == "dead", na.rm = TRUE)
  deaths_b <- sum(data$vital_status_30d[data$arm == arms[2]] == "dead", na.rm = TRUE)
  n_a <- sum(data$arm == arms[1])
  n_b <- sum(data$arm == arms[2])

  mortality_a <- beta_posterior(deaths_a, n_a, priors$mortality$arm_prior$alpha,
                                priors$mortality$arm_prior$beta)
  mortality_b <- beta_posterior(deaths_b, n_b, priors$mortality$arm_prior$alpha,
                                priors$mortality$arm_prior$beta)
  mortality_comparison <- beta_difference(
    mortality_a, mortality_b,
    draws = priors$posterior$draws, seed = priors$posterior$seed,
    higher_is_better = FALSE
  )

  list(
    domain = data$domain[1],
    population = population,
    arms = arms,
    outcome_sd_used = sigma,

    counts = list(
      records = nrow(data),
      arm_a = n_a,
      arm_b = n_b,
      no_allocation_recorded = no_allocation,
      not_evaluable = sum(is.na(outcome)),
      incomplete = sum(!data$complete, na.rm = TRUE),
      complete = sum(data$complete, na.rm = TRUE)
    ),

    primary = list(
      arm_a = posterior_a,
      arm_b = posterior_b,
      comparison = comparison,
      decision = decision,
      allocation = as.list(allocation)
    ),

    mortality_30d = list(
      arm_a = mortality_a,
      arm_b = mortality_b,
      comparison = mortality_comparison
    )
  )
}

#' Run the pre-specified adaptive analysis on a frozen cut
#'
#' Takes a cut ID and nothing else, as the specification requires. Verifies the
#' cut before reading it, applies the pre-specified priors and thresholds, and
#' writes a signed analysis record.
#'
#' @param cut_id Identifier of the cut to analyse.
#' @param cuts_dir Directory holding the cuts.
#' @param output_dir Directory to write analysis records into.
#' @param priors,rules Pre-specified configuration; loaded if not supplied.
#' @param prior_record_path Recorded prior predictive check the gate reads.
#' @param analysed_at Timestamp; overridable so a reproduction can compare
#'   results without the clock differing.
#' @return The analysis record, invisibly.
run_adaptive_analysis <- function(cut_id,
                                  cuts_dir = project_path("data", "cuts"),
                                  output_dir = project_path("data", "analyses"),
                                  priors = load_priors(),
                                  rules = load_decision_rules(),
                                  prior_record_path = project_path(
                                    "config", "prior_predictive_record.yml"),
                                  analysed_at = Sys.time()) {

  # 1. Refuse to run under priors that have no recorded, passing prior
  #    predictive check. The check belongs at SAP finalisation, as a condition
  #    of the plan taking effect. Enforcing it here turns a discipline somebody
  #    is supposed to remember into a state the code will not proceed without.
  assert_prior_predictive_passed(record_path = prior_record_path)

  # 2. Refuse to run on a cut that does not verify. This is the seam the whole
  #    design exists to protect.
  verification <- verify_cut(cut_id, cuts_dir)
  if (!verification$verified) {
    stop("Refusing to analyse cut '", cut_id, "': manifest verification failed.",
         "\n  altered: ", paste(verification$mismatched, collapse = ", "),
         "\n  missing: ", paste(verification$missing, collapse = ", "),
         "\n  unexpected: ", paste(verification$unexpected, collapse = ", "),
         call. = FALSE)
  }

  manifest <- read_cut_manifest(cut_id, cuts_dir)
  cut_data <- read_cut(cut_id, cuts_dir, verify = FALSE)  # just verified above

  domains <- sort(unique(cut_data$randomisation$domain))
  results <- list()

  for (domain in domains) {
    itt <- analysis_dataset(cut_data, domain)
    if (!nrow(itt)) next

    domain_result <- analyse_domain(itt, priors, rules, population = "itt")

    # Complete-case sensitivity analysis, reported alongside rather than
    # instead of the primary. The two differ by more than the equivalence
    # margin in this dataset, which is exactly why both are shown.
    complete_only <- itt[isTRUE_vector(itt$complete), ]
    domain_result$complete_case <- if (nrow(complete_only) > 10) {
      analyse_domain(complete_only, priors, rules, population = "complete_case")
    } else {
      NULL
    }

    results[[domain]] <- domain_result
  }

  record <- list(
    analysis_id = sprintf("ANA-%s-%s", cut_id,
                          format(as.POSIXct(analysed_at, tz = "UTC"),
                                 "%Y%m%dT%H%M%SZ", tz = "UTC")),
    analysed_at = format(as.POSIXct(analysed_at, tz = "UTC"),
                         "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),

    cut = list(
      cut_id = cut_id,
      as_of_date = manifest$as_of_date,
      manifest_files = manifest$files,
      participants = manifest$contents$participants
    ),

    specification = list(
      sap_version = SAP_VERSION,
      priors_version = priors$version,
      decision_rules_version = rules$version,
      priors_file_sha256 = file_sha256(project_path("config", "priors.yml")),
      decision_rules_file_sha256 = file_sha256(
        project_path("config", "decision_rules.yml")),
      thresholds = rules$thresholds
    ),

    environment = list(
      r_version = R.version.string,
      git_commit = cut_provenance_git_commit(),
      package_versions = list(
        dplyr = as.character(utils::packageVersion("dplyr")),
        arrow = as.character(utils::packageVersion("arrow"))
      )
    ),

    domains = results
  )

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(record,
                       file.path(output_dir, paste0(record$analysis_id, ".json")),
                       auto_unbox = TRUE, pretty = TRUE, digits = NA)

  invisible(record)
}

#' The current git commit, or NA outside a repository
#'
#' @return A character SHA or NA.
cut_provenance_git_commit <- function() {
  tryCatch({
    sha <- system2("git", c("rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE)
    if (length(sha)) sha[1] else NA_character_
  }, error = function(e) NA_character_, warning = function(w) NA_character_)
}

#' TRUE where a logical vector is TRUE, treating NA as FALSE
#'
#' `x[NA]` returns a row of NAs rather than dropping it, which silently pads a
#' filtered data frame with empty rows. This makes the intent explicit.
#'
#' @param x A logical vector.
#' @return A logical vector with NA replaced by FALSE.
isTRUE_vector <- function(x) !is.na(x) & x

#' Summarise an analysis record as a table
#'
#' @param record Output of [run_adaptive_analysis()].
#' @return A data frame, one row per domain.
summarise_analysis <- function(record) {
  rows <- lapply(record$domains, function(result) {
    data.frame(
      domain = result$domain,
      arm_a = result$arms[1],
      arm_b = result$arms[2],
      n_a = result$counts$arm_a,
      n_b = result$counts$arm_b,
      mean_a = round(result$primary$arm_a$observed_mean, 2),
      mean_b = round(result$primary$arm_b$observed_mean, 2),
      difference = round(result$primary$comparison$difference_mean, 3),
      ci_lower = round(result$primary$comparison$credible_interval_lower, 2),
      ci_upper = round(result$primary$comparison$credible_interval_upper, 2),
      p_a_better = round(result$primary$comparison$probability_a_better, 4),
      p_equivalent = round(result$primary$comparison$probability_equivalent, 4),
      decision = result$primary$decision$decision,
      alloc_a = round(result$primary$allocation$a, 3),
      alloc_b = round(result$primary$allocation$b, 3),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}
