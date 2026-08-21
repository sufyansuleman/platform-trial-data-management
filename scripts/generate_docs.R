# ---------------------------------------------------------------------------
# Generate docs/data_dictionary.md and docs/validation_plan.md.
#
#   Rscript scripts/generate_docs.R
#
# Both documents are generated from the same YAML the pipeline itself reads.
# Hand-written versions of these two files drift out of step with the code the
# first time somebody adds a column or a rule and forgets the documentation --
# and a data dictionary that disagrees with the database is worse than none,
# because people trust it.
#
# The narrative sections that explain *why* are written by hand and live in
# this script, so they are reviewed alongside the structure they describe.
# ---------------------------------------------------------------------------

suppressMessages(library(dplyr))

for (file in list.files("R", pattern = "[.]R$", recursive = TRUE,
                        full.names = TRUE)) {
  source(file)
}

cfg <- load_trial_config()
generated_note <- sprintf(
  paste("> **Generated file.** Produced by `scripts/generate_docs.R` from",
        "`config/`. Edit the configuration, not this file. Last generated %s."),
  format(Sys.Date(), "%d %B %Y"))

# ---------------------------------------------------------------------------
# Data dictionary
# ---------------------------------------------------------------------------

field_row <- function(spec) {
  constraint <- character()
  if (!is.null(spec$allowed)) {
    constraint <- c(constraint, paste0("one of: `",
                                       paste(unlist(spec$allowed), collapse = "`, `"), "`"))
  }
  if (!is.null(spec$min) || !is.null(spec$max)) {
    constraint <- c(constraint, sprintf("%s to %s",
                                        spec$min %||% "-", spec$max %||% "-"))
  }
  if (!is.null(spec$pattern)) {
    constraint <- c(constraint, paste0("matches `", spec$pattern, "`"))
  }

  sprintf("| `%s` | %s | %s | %s | %s |",
          spec$name,
          spec$type,
          if (isTRUE(spec$required)) "yes" else "no",
          if (length(constraint)) paste(constraint, collapse = "; ") else "—",
          trimws(gsub("\\s+", " ", spec$description %||% "")))
}

dictionary <- c(
  "# Data dictionary",
  "",
  generated_note,
  "",
  "Every field in every form, with its type, whether it is required, and the",
  "constraints the schema enforces. These are the **hard bounds**: a value",
  "outside them is certainly wrong. The tighter *plausibility* bounds that",
  "generate queries live in [validation_plan.md](validation_plan.md) and are",
  "deliberately narrower — see rule RNG-001 for why.",
  "",
  "## Conventions",
  "",
  "- **No free text anywhere.** Every field is coded, dated or numeric. This",
  "  keeps the dataset trivially safe to share and models good clinical data",
  "  management practice: free text cannot be validated, cannot be analysed",
  "  without manual coding, and is where identifiable information leaks into",
  "  a trial database.",
  "- **No dates of birth.** Age in whole years only.",
  "- **Identifiers are trial-generated.** No national identifier, hospital",
  "  number or any other externally meaningful key appears in the data.",
  "- **Internal units are kilograms and micromoles per litre.** Sites may",
  "  export in pounds or mg/dL; ingest converts and logs the conversion.",
  "- **Dates are stored as ISO 8601** after ingest. Sites export in their own",
  "  local format.",
  ""
)

for (form in schema_forms()) {
  schema <- load_schema(form)
  key <- paste0("`", paste(unlist(schema$key), collapse = "` + `"), "`")
  dictionary <- c(
    dictionary,
    sprintf("## `%s`", form),
    "",
    sprintf("**Grain.** %s", schema$grain),
    "",
    sprintf("**Key.** %s", key),
    "",
    "| Field | Type | Required | Constraint | Description |",
    "|---|---|---|---|---|",
    vapply(schema$columns, field_row, character(1)),
    ""
  )
}

dictionary <- c(
  dictionary,
  "## Derived variables",
  "",
  "Not captured on any form; computed by `R/derive/`.",
  "",
  "| Variable | Definition |",
  "|---|---|",
  paste("| `days_alive_without_life_support` | Days in the 30 days after",
        "randomisation into that domain on which the participant was alive and",
        "free of invasive mechanical ventilation, vasopressor or inotropic",
        "support, and renal replacement therapy. Death within 30 days scores 0.",
        "See DEC-012 and DEC-013. |"),
  paste("| `unknown_days` | Days in the window whose status could not be",
        "determined, because no record exists and no discharge explains its",
        "absence, or because duplicate records disagree. |"),
  paste("| `complete` | Whether the endpoint rests entirely on observed days.",
        "|"),
  ""
)

writeLines(dictionary, "docs/data_dictionary.md")
message("Wrote docs/data_dictionary.md")

# ---------------------------------------------------------------------------
# Validation plan
# ---------------------------------------------------------------------------

rules <- load_rules()

severity_definitions <- c(
  "## Severity and what happens when a rule fires",
  "",
  "Severity describes the consequence for the trial, not the difficulty of",
  "fixing the problem. It determines how quickly somebody has to act.",
  "",
  "| Severity | Meaning | Response |",
  "|---|---|---|",
  paste("| `critical` | The analysis population, the primary outcome or a",
        "participant's identity is affected. The finding makes some part of the",
        "dataset unusable until resolved. | Escalated to the coordinating centre",
        "the same working day. Not closed by the site alone. |"),
  paste("| `major` | A required value is absent or implausible. The record is",
        "usable but incomplete or suspect. | Query raised with the site.",
        "Expected turnaround 14 days. |"),
  paste("| `minor` | A value that supports interpretation is missing but no",
        "analysis depends on it. | Query raised, batched with the site's next",
        "routine contact. |"),
  paste("| `informational` | Recorded for monitoring purposes; no site action",
        "expected. | Reported in the central monitoring report only. |"),
  "",
  "The `action` field on each rule states which of these applies:",
  "`query` raises a query with the site, `escalate` also notifies the",
  "coordinating centre.",
  ""
)

plan <- c(
  "# Validation plan",
  "",
  generated_note,
  "",
  "This document is the standard operating procedure for data validation: what",
  "is checked, why it is checked, how serious a failure is, and what happens",
  "when one occurs.",
  "",
  "## How validation works here",
  "",
  "**The engine is generic; the rules are data.** No R code knows what a",
  "vasopressor is or that discharge follows admission. Every check lives in",
  "`config/rules/*.yml` as an expression, a severity, a description and a",
  "rationale. A clinician or trial manager can read the entire rule set, and",
  "propose a new rule, without reading any R.",
  "",
  "**The output is a findings dataset, not a pass or fail.** The purpose of",
  "validation is to tell somebody what to fix. Each finding carries the site,",
  "the participant, the form, the field and the observed value, so it can be",
  "acted on rather than merely counted.",
  "",
  "**A rule that cannot be evaluated does not fire.** If a rule depends on a",
  "field that is itself missing, it returns no finding: the missingness is",
  "already reported by STR-001, and reporting it twice would send the site two",
  "queries for one problem.",
  "",
  "**The rule set is versioned.** Every finding records a hash of the rule",
  "files that produced it, so a finding raised a year ago remains interpretable",
  "after the rules have changed.",
  "",
  sprintf("The current rule set is `%s` and contains **%d rules**.",
          rule_set_version(), length(rules)),
  "",
  severity_definitions,
  "## How the rules are known to work",
  "",
  "The pipeline injects a catalogue of known defects into the synthetic data",
  "and records ground truth for every one. The validation engine is then scored",
  "against that catalogue, so its performance is measured rather than asserted,",
  "and the rules it misses are reported alongside the ones it catches. The",
  "current figures are in the README and in the central monitoring report.",
  "",
  "Three injected defect types have no rule in this rule set: entry-delay",
  "drift, terminal-digit preference and adverse-event under-reporting. None of",
  "them can be detected in a single record — every individual record is valid —",
  "and they are addressed by statistical monitoring instead. They are reported",
  "as not applicable rather than as failures, because scoring a rule set",
  "against defects it was never written to catch would misrepresent it.",
  "",
  "## The rules",
  ""
)

by_file <- split(rules, vapply(rules, function(r) r$source_file, character(1)))
file_titles <- c(
  structural.yml = "Structural — types, keys, required fields, referential integrity",
  range.yml = "Range — physiological plausibility",
  logic.yml = "Logic — cross-field and cross-form consistency",
  temporal.yml = "Temporal — date sequencing",
  cross_domain.yml = "Cross-domain — participants entered in more than one domain"
)

for (source_file in names(file_titles)) {
  if (is.null(by_file[[source_file]])) next
  plan <- c(plan,
            sprintf("### %s", file_titles[[source_file]]),
            "",
            sprintf("Defined in `config/rules/%s`.", source_file),
            "")

  for (rule in by_file[[source_file]]) {
    tidy <- function(x) trimws(gsub("\\s+", " ", x))
    bounds <- if (!is.null(rule$min) && !is.null(rule$max)) {
      sprintf(" Bounds: %s to %s.", rule$min, rule$max)
    } else ""

    plan <- c(
      plan,
      sprintf("#### %s — %s", rule$id, gsub("_", " ", rule$name)),
      "",
      sprintf("| | |"),
      sprintf("|---|---|"),
      sprintf("| **Applies to** | %s |", paste0("`", paste(unlist(rule$scope), collapse = "`, `"), "`")),
      sprintf("| **Severity** | `%s` |", rule$severity),
      sprintf("| **Action** | `%s` |", rule$action),
      sprintf("| **Expression** | `%s` |", rule$expression),
      "",
      sprintf("**What it checks.** %s%s", tidy(rule$description), bounds),
      "",
      sprintf("**Why it matters.** %s", tidy(rule$rationale)),
      ""
    )
  }
}

plan <- c(
  plan,
  "## Vocabulary available to rule authors",
  "",
  "Rule expressions may use any field on the form they are scoped to, plus the",
  "derived context columns below. These exist so that a rule needing a fact",
  "from another form stays readable as prose rather than becoming a join.",
  "They are computed in `R/validate/context.R`.",
  "",
  "| Column | Available on | Meaning |",
  "|---|---|---|",
  "| `first_randomisation_date` | `outcome_30d`, `adverse_events` | Earliest randomisation across all domains for this participant. |",
  "| `domain_randomisation_date` | `outcome_30d` | Randomisation date for *this* domain. |",
  "| `window_end_date` | `outcome_30d` | Thirty days after this domain's randomisation. |",
  "| `participant_is_randomised` | follow-up forms | Whether the participant has any randomisation record. |",
  "| `sites_using_participant_id` | `screening` | Number of distinct sites using this identifier. |",
  "| `randomisations_in_domain` | `randomisation` | Randomisation records for this participant in this domain. |",
  "| `days_since_previous_record` | `daily_icu` | Gap in days to the previous daily record; 1 is consecutive. |",
  "| `death_date_or_infinity` | `daily_icu` | Date of death, or a date nothing can exceed when none is recorded. |",
  "| `death_date_and_status_agree` | `outcome_30d` | Whether vital status and the presence of a death date are consistent. |",
  "| `distinct_death_dates_for_participant` | `outcome_30d` | Distinct death dates recorded across domains. |",
  "| `distinct_admission_dates_for_participant` | `outcome_30d` | Distinct ICU admission dates across domains. |",
  "| `vital_status_consistent_at_shared_window` | `outcome_30d` | Whether domains sharing a window end date agree on vital status. |",
  "| `screening_date_for_participant` | `randomisation` | Screening date for this participant. |",
  "| `entry_not_before_event` | all forms | Whether the record was entered on or after the event it describes. |",
  "",
  "Adding a context column is how the vocabulary grows. A new column must be",
  "added to `R/validate/context.R`, documented in this table, and covered by a",
  "test in `tests/testthat/test-validation-rules.R`.",
  ""
)

writeLines(plan, "docs/validation_plan.md")
message("Wrote docs/validation_plan.md")
message("\nBoth documents regenerated. Commit them alongside the config change.")
