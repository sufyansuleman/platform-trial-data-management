# ---------------------------------------------------------------------------
# Print, and save, a summary of what a pipeline run produced.
#
# Run after targets::tar_make(). Used by CI so that a run's log carries the
# numbers a reviewer would want to see -- row counts, findings, rule recall and
# endpoint completeness -- rather than only a green tick.
#
#   Rscript scripts/pipeline_summary.R
# ---------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(targets)
})

# tar_read() returns stored values but does not load the project's functions,
# and this script calls some of them to format the output.
for (file in list.files("R", pattern = "[.]R$", recursive = TRUE,
                        full.names = TRUE)) {
  source(file)
}

output_dir <- "build"
dir.create(output_dir, showWarnings = FALSE)

rule <- function(title) {
  cat("\n", strrep("=", 78), "\n", title, "\n", strrep("=", 78), "\n", sep = "")
}

rule("ROW COUNTS PER FORM")
row_counts <- tar_read(row_counts)
print(row_counts, row.names = FALSE)

rule("EDC EXPORT")
manifest <- tar_read(edc_export_manifest)
cat("files written:", nrow(manifest), "across", length(unique(manifest$site_id)),
    "sites\n")

rule("INGEST CONFORMANCE LOG")
conformance <- conformance_summary(tar_read(conformance_log))
print(conformance, row.names = FALSE)

rule("VALIDATION FINDINGS BY RULE")
findings_summary <- tar_read(findings_summary)
print(findings_summary[, c("rule_id", "rule_name", "severity", "form",
                           "findings", "sites")], row.names = FALSE)
cat("\ntotal findings:", sum(findings_summary$findings), "\n")

rule("RULE RECALL AGAINST INJECTED DEFECTS")
recall <- tar_read(recall_table)
recall$recall <- ifelse(is.na(recall$recall), "n/a",
                        sprintf("%.1f%%", 100 * recall$recall))
print(recall, row.names = FALSE)

overall <- tar_read(recall_summary)
cat(sprintf("\noverall recall: %d of %d scoreable defect records = %.1f%%\n",
            overall$detected, overall$scoreable_by_a_rule, 100 * overall$recall))
cat(sprintf("defect records with no Milestone 1 rule (monitoring signals): %d\n",
            overall$not_scoreable_monitoring_signals))

rule("PRIMARY ENDPOINT: DAYS ALIVE WITHOUT LIFE SUPPORT")
print(tar_read(dawols_summary), row.names = FALSE)
cat("\nby domain:\n")
print(tar_read(dawols_by_domain), row.names = FALSE)

# Persist the machine-readable pieces so a CI run can be inspected after the
# fact without rerunning it.
write.csv(row_counts, file.path(output_dir, "row_counts.csv"), row.names = FALSE)
write.csv(findings_summary, file.path(output_dir, "findings_by_rule.csv"), row.names = FALSE)
write.csv(recall, file.path(output_dir, "rule_recall.csv"), row.names = FALSE)
write.csv(tar_read(dawols_summary), file.path(output_dir, "endpoint_summary.csv"),
          row.names = FALSE)

cat("\nSummary written to", normalizePath(output_dir), "\n")
