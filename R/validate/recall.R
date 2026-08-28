# ---------------------------------------------------------------------------
# Scoring the rule set against the injected-defect ground truth.
#
# Without this file, "the rules found 3,000 problems" is an unfalsifiable
# claim. With it, the claim becomes "the rules found this proportion of the
# problems we know are there, and missed these".
#
# Being able to say what the rules MISS is the point. A validation plan that
# only reports what it catches is marketing.
# ---------------------------------------------------------------------------

#' Match injected defects to findings
#'
#' A defect counts as detected when the rule it was tagged with produced a
#' finding for the same participant on the same form. The field must also
#' agree where both sides name one: a rule that fires on a different field of
#' the same record has not detected this defect, it has detected something
#' else.
#'
#' Rules that name no field -- LOG-002 checks a record, not a column -- match
#' any field, since there is nothing to disagree about.
#'
#' @param defects Ground-truth catalogue from [inject_defects()].
#' @param findings Findings table from [run_validation()].
#' @return `defects` with a logical `detected` column added.
match_defects_to_findings <- function(defects, findings) {
  defects$defect_row <- seq_len(nrow(defects))

  scoreable <- defects[!is.na(defects$expected_rule_id), ]
  if (!nrow(scoreable) || !nrow(findings)) {
    defects$detected <- FALSE
    return(defects)
  }

  matched <- scoreable |>
    dplyr::inner_join(
      findings[, c("rule_id", "form", "participant_id", "field")],
      by = c("expected_rule_id" = "rule_id", "form" = "form",
             "participant_id" = "participant_id"),
      relationship = "many-to-many",
      suffix = c("_defect", "_finding")
    ) |>
    dplyr::filter(is.na(field_defect) | is.na(field_finding) |
                    field_defect == field_finding) |>
    dplyr::pull(defect_row) |>
    unique()

  defects$detected <- defects$defect_row %in% matched
  defects
}

#' Recall per defect type
#'
#' The table the README carries. Defect types with no expected rule are
#' reported separately rather than scored, because counting a defect that no
#' rule was ever written to catch as a miss would misrepresent the rule set,
#' and quietly dropping it would misrepresent the defect catalogue.
#'
#' @param defects Ground truth, already matched by [match_defects_to_findings()].
#' @return A data frame, one row per defect type.
recall_by_defect_type <- function(defects) {
  scored <- defects |>
    dplyr::group_by(defect_id, defect_name, expected_rule_id) |>
    dplyr::summarise(
      injected = dplyr::n(),
      detected = sum(detected),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      recall = ifelse(is.na(expected_rule_id), NA_real_, detected / injected),
      expected_rule_id = dplyr::coalesce(expected_rule_id, "none - monitoring signal")
    ) |>
    as.data.frame()

  scored[order(scored$defect_id), ]
}

#' Findings that no injected defect accounts for
#'
#' Reported deliberately, and NOT labelled false positives. A finding with no
#' matching injected defect is one of three things:
#'
#'   1. A genuine problem the simulator created incidentally rather than by
#'      injection -- a randomly generated value that happens to be implausible.
#'   2. A real ambiguity in the data model. LOG-001 is the clearest case: with
#'      no ICU discharge date on any form, a gap caused by discharge and
#'      readmission is indistinguishable from a gap caused by missing entry.
#'      Querying both is what a data manager would actually do.
#'   3. A rule that is genuinely too eager.
#'
#' Only the third is a defect in the rule set, and telling them apart needs
#' judgement, so this function reports the counts and leaves the judgement to
#' the reader.
#'
#' @param findings Findings table.
#' @param defects Ground truth.
#' @return A data frame, one row per rule.
unmatched_findings_by_rule <- function(findings, defects) {
  if (!nrow(findings)) return(findings)

  keys <- defects[!is.na(defects$expected_rule_id), ]
  traceable <- paste(keys$expected_rule_id, keys$form, keys$participant_id)
  findings$traceable <- paste(findings$rule_id, findings$form,
                              findings$participant_id) %in% traceable

  findings |>
    dplyr::group_by(rule_id, rule_name, severity) |>
    dplyr::summarise(
      findings = dplyr::n(),
      traceable_to_injected_defect = sum(traceable),
      not_traceable = sum(!traceable),
      .groups = "drop"
    ) |>
    as.data.frame()
}

#' Overall recall summary line
#'
#' @param defects Ground truth, already matched.
#' @return A one-row data frame.
recall_overall <- function(defects) {
  scoreable <- defects[!is.na(defects$expected_rule_id), ]
  data.frame(
    defect_records_injected = nrow(defects),
    scoreable_by_a_rule = nrow(scoreable),
    detected = sum(scoreable$detected),
    recall = sum(scoreable$detected) / nrow(scoreable),
    not_scoreable_monitoring_signals = nrow(defects) - nrow(scoreable),
    stringsAsFactors = FALSE
  )
}
