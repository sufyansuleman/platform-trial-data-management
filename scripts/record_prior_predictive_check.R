# ---------------------------------------------------------------------------
# Run the prior predictive check and record the verdict.
#
#   Rscript scripts/record_prior_predictive_check.R
#
# Run this at SAP finalisation, BEFORE any analysis. The recorded verdict is
# what run_adaptive_analysis() reads before it will start, and the record is
# bound to a hash of config/priors.yml so that editing a prior afterwards
# invalidates it rather than silently inheriting the old verdict.
# ---------------------------------------------------------------------------

suppressMessages(library(dplyr))
for (file in list.files("R", pattern = "[.]R$", recursive = TRUE,
                        full.names = TRUE)) {
  source(file)
}

record <- record_prior_predictive_check()

cat("Prior predictive check\n")
cat("  priors version:", record$priors_version, "\n")
cat("  outside outcome bounds:      ",
    sprintf("%.3f (limit %.2f) %s\n", record$results$proportion_outside_outcome_bounds,
            record$criteria$max_proportion_outside_bounds,
            if (record$outcome$bounds_criterion_met) "ok" else "FAIL"))
cat("  effects implausibly large:   ",
    sprintf("%.3f (limit %.2f) %s\n", record$results$proportion_effect_implausibly_large,
            record$criteria$max_proportion_effect_implausible,
            if (record$outcome$effect_criterion_met) "ok" else "FAIL"))
cat("  implied effect prior sd:     ", record$results$prior_effect_sd, "\n")
cat("\n  STATUS:", toupper(record$status), "\n")

if (record$status != "pass") {
  cat("\nThe analysis engine will refuse to run under these priors.\n")
}
