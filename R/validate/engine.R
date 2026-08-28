# ---------------------------------------------------------------------------
# The rule engine.
#
# The engine is generic; the rules are data. Nothing in this file knows what a
# vasopressor is, or that discharge follows admission. It loads rules from
# config/rules/*.yml, evaluates each one against the form it names, and returns
# a findings table.
#
# That separation is the most important design decision in the project. It
# means a clinician or trial manager can read every check the pipeline
# performs, and propose a new one, without reading any R at all.
#
# The output is a findings dataset, not a pass/fail verdict. The point of
# validation is to tell somebody what to fix.
# ---------------------------------------------------------------------------

VALID_SEVERITIES <- c("critical", "major", "minor", "informational")

#' Load and validate the rule set
#'
#' Every rule is checked for the fields the engine relies on before any data is
#' touched, so a malformed rule fails immediately rather than halfway through a
#' pipeline run.
#'
#' @param dir Directory holding the rule YAML files.
#' @return A list of rules, each carrying the file it came from.
load_rules <- function(dir = project_path("config", "rules")) {
  files <- list.files(dir, pattern = glob2rx("*.yml"), full.names = TRUE)
  if (!length(files)) stop("No rule files found in '", dir, "'.", call. = FALSE)

  rules <- unlist(lapply(files, function(path) {
    parsed <- yaml::read_yaml(path)
    lapply(parsed, function(rule) {
      rule$source_file <- basename(path)
      rule
    })
  }), recursive = FALSE)

  for (rule in rules) {
    for (field in c("id", "name", "scope", "severity", "description",
                    "rationale", "expression", "action")) {
      if (is.null(rule[[field]])) {
        stop("Rule '", rule$id %||% "(no id)", "' in ", rule$source_file,
             " is missing required field '", field, "'.", call. = FALSE)
      }
    }
    if (!rule$severity %in% VALID_SEVERITIES) {
      stop("Rule '", rule$id, "' has severity '", rule$severity,
           "', which is not one of: ", paste(VALID_SEVERITIES, collapse = ", "),
           call. = FALSE)
    }
  }

  ids <- vapply(rules, function(r) r$id, character(1))
  if (anyDuplicated(ids)) {
    stop("Duplicate rule id(s): ",
         paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)
  }
  rules
}

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Version identifier for the rule set
#'
#' A short hash of the rule files. Recorded on every finding and in every data
#' cut manifest, so a finding can always be traced to the exact rules that
#' produced it -- rules change over a trial's life, and a finding raised under
#' an old rule set must remain interpretable.
#'
#' @param dir Directory holding the rule YAML files.
#' @return A 12-character hash.
rule_set_version <- function(dir = project_path("config", "rules")) {
  files <- sort(list.files(dir, pattern = glob2rx("*.yml"), full.names = TRUE))
  substr(digest::digest(lapply(files, readLines)), 1, 12)
}

#' Expand a rule into the concrete checks it implies
#'
#' Most rules are one check. Two forms of shorthand expand into several:
#'
#'   * `scope` naming multiple forms runs the rule once per form.
#'   * `fields: required` runs the rule once per required field in that form's
#'     schema, which is how STR-001 covers every required field without
#'     listing them and drifting out of step with the schema.
#'
#' @param rule A rule from [load_rules()].
#' @return A list of concrete checks, each with a single `form` and `field`.
expand_rule <- function(rule) {
  forms <- unlist(rule$scope)
  checks <- list()

  for (form in forms) {
    fields <- if (identical(rule$fields, "required")) {
      schema <- load_schema(form)
      names <- vapply(schema$columns, function(c) c$name, character(1))
      required <- vapply(schema$columns, function(c) isTRUE(c$required), logical(1))
      names[required]
    } else {
      rule$field %||% NA_character_
    }

    for (field in fields) {
      check <- rule
      check$form <- form
      check$field <- field
      checks[[length(checks) + 1]] <- check
    }
  }
  checks
}

#' Evaluate one concrete check against one form
#'
#' The expression is evaluated with the form's columns in scope, plus the two
#' engine-provided helpers that make field-parameterised rules possible:
#'
#'   * `.not_missing` -- TRUE where the check's field has a value
#'   * `.in_range`    -- TRUE where the check's field lies within min and max
#'
#' A rule returning NA for a record means the rule could not be evaluated
#' there, usually because a field it depends on is itself missing. Those
#' records are NOT reported as violations: the missingness is already reported
#' by STR-001, and reporting it twice would inflate the findings count and send
#' the site two queries for one problem.
#'
#' @param check A concrete check from [expand_rule()].
#' @param data The form, with context columns attached.
#' @return A logical vector: TRUE passed, FALSE violated, NA not evaluable.
evaluate_check <- function(check, data) {
  scope <- as.list(data)

  if (!is.na(check$field) && check$field %in% names(data)) {
    value <- data[[check$field]]
    scope$.not_missing <- !is.na(value)
    scope$.in_range <- if (!is.null(check$min) && !is.null(check$max)) {
      value >= check$min & value <= check$max
    } else {
      rep(NA, length(value))
    }
  }

  result <- tryCatch(
    eval(parse(text = check$expression), envir = scope),
    error = function(e) {
      stop("Rule '", check$id, "' failed to evaluate against form '",
           check$form, "': ", conditionMessage(e),
           "\n  expression: ", check$expression, call. = FALSE)
    }
  )

  if (length(result) == 1) result <- rep(result, nrow(data))
  if (!is.logical(result) || length(result) != nrow(data)) {
    stop("Rule '", check$id, "' must return one logical value per row of '",
         check$form, "'; got ", class(result)[1], " of length ", length(result),
         ".", call. = FALSE)
  }
  result
}

#' Run the full rule set and return a findings table
#'
#' One row per violation. Deliberately not a pass/fail summary: the purpose of
#' validation is to give a coordinator a list of things to act on, with enough
#' identifying detail to act on them.
#'
#' @param forms Conformed forms, before context is attached.
#' @param sites Resolved site table, used to attach country to each finding.
#' @param rules Rule set; loaded from config if not supplied.
#' @param data_version Identifier for the dataset being validated.
#' @param detected_at Timestamp recorded on every finding.
#' @return A data frame of findings.
run_validation <- function(forms, sites, rules = load_rules(),
                           data_version = "working",
                           detected_at = Sys.time()) {
  enriched <- build_rule_context(forms)
  findings <- list()

  for (rule in rules) {
    for (check in expand_rule(rule)) {
      data <- enriched[[check$form]]
      if (is.null(data)) {
        stop("Rule '", check$id, "' is scoped to form '", check$form,
             "', which is not present in the dataset.", call. = FALSE)
      }

      result <- evaluate_check(check, data)
      violated <- which(!is.na(result) & !result)
      if (!length(violated)) next

      observed <- if (!is.na(check$field) && check$field %in% names(data)) {
        as.character(data[[check$field]][violated])
      } else {
        NA_character_
      }

      findings[[length(findings) + 1]] <- data.frame(
        rule_id        = check$id,
        rule_name      = check$name,
        severity       = check$severity,
        action         = check$action,
        site_id        = data$site_id[violated],
        participant_id = if ("participant_id" %in% names(data)) {
          data$participant_id[violated]
        } else NA_character_,
        domain         = if ("domain" %in% names(data)) {
          data$domain[violated]
        } else NA_character_,
        form           = check$form,
        field          = check$field,
        observed_value = observed,
        stringsAsFactors = FALSE
      )
    }
  }

  if (!length(findings)) {
    return(empty_findings())
  }

  out <- do.call(rbind, findings)
  out$country <- sites$country[match(out$site_id, sites$site_id)]
  out$detected_at <- detected_at
  out$data_version <- data_version
  out$rule_set_version <- rule_set_version()
  out$finding_id <- sprintf("FND-%07d", seq_len(nrow(out)))

  out[, c("finding_id", "rule_id", "rule_name", "severity", "action",
          "site_id", "country", "participant_id", "domain", "form", "field",
          "observed_value", "detected_at", "data_version", "rule_set_version")]
}

#' An empty findings table with the correct columns
#'
#' Returned when nothing is violated, so downstream code never has to test for
#' NULL before selecting a column.
#'
#' @return A zero-row data frame.
empty_findings <- function() {
  data.frame(
    finding_id = character(), rule_id = character(), rule_name = character(),
    severity = character(), action = character(), site_id = character(),
    country = character(), participant_id = character(), domain = character(),
    form = character(), field = character(), observed_value = character(),
    detected_at = as.POSIXct(character()), data_version = character(),
    rule_set_version = character(), stringsAsFactors = FALSE
  )
}

#' Summarise findings by rule and severity
#'
#' @param findings Findings table from [run_validation()].
#' @return A data frame ordered by severity then count.
findings_by_rule <- function(findings) {
  if (!nrow(findings)) return(findings)
  out <- findings |>
    dplyr::group_by(rule_id, rule_name, severity, form) |>
    dplyr::summarise(findings = dplyr::n(),
                     participants = dplyr::n_distinct(participant_id),
                     sites = dplyr::n_distinct(site_id),
                     .groups = "drop") |>
    as.data.frame()
  out$severity <- factor(out$severity, levels = VALID_SEVERITIES)
  out[order(out$severity, -out$findings), ]
}

#' Summarise findings by site and severity
#'
#' @param findings Findings table.
#' @return A wide data frame, one row per site.
findings_by_site <- function(findings) {
  if (!nrow(findings)) return(findings)
  counts <- table(findings$site_id,
                  factor(findings$severity, levels = VALID_SEVERITIES))
  out <- as.data.frame.matrix(counts)
  out$site_id <- rownames(out)
  out$total <- rowSums(counts)
  rownames(out) <- NULL
  out[order(-out$critical, -out$total), c("site_id", VALID_SEVERITIES, "total")]
}
