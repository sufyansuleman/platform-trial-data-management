# ---------------------------------------------------------------------------
# Pipeline definition.
#
# Run with:  Rscript -e 'targets::tar_make()'
# Inspect:   Rscript -e 'targets::tar_visnetwork()'
#
# The DAG is deliberately linear at this stage: configuration feeds the
# simulation, the simulation feeds defect injection, and defect injection feeds
# both the simulated EDC export and the ground-truth catalogue that the
# validation engine is later scored against.
# ---------------------------------------------------------------------------

library(targets)

# Every function in R/ is sourced; there is no package structure, deliberately,
# because a reader should be able to open any file and run it.
tar_source("R")

tar_option_set(
  packages = c("yaml", "arrow", "dplyr", "tidyr", "digest", "jsonlite"),
  format = "rds"
)

list(
  # -- Configuration --------------------------------------------------------
  # Tracked as files so that editing a rule or a trial parameter invalidates
  # exactly the downstream targets that depend on it.
  tar_target(trial_config_file, "config/trial.yml", format = "file"),
  tar_target(schema_files, list.files("config/schema", full.names = TRUE), format = "file"),

  tar_target(trial_config, load_trial_config(trial_config_file)),
  tar_target(sites, resolve_sites(trial_config)),

  # -- Simulation -----------------------------------------------------------
  tar_target(clean_forms, simulate_trial(trial_config)),

  tar_target(injected, {
    schema_files  # declare the dependency: injectors read the schemas
    inject_defects(clean_forms, trial_config)
  }),

  tar_target(raw_forms, injected$forms),
  tar_target(injected_defects, injected$defects),

  # -- Persisted artefacts --------------------------------------------------
  # Ground truth for scoring the validation engine. Written to Parquet so it
  # can be read by anything, not just R.
  tar_target(
    injected_defects_file,
    {
      path <- "data/interim/injected_defects.parquet"
      dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
      arrow::write_parquet(injected_defects, path)
      path
    },
    format = "file"
  ),

  # The simulated EDC exports: one CSV per site per form, each in that site's
  # own local conventions.
  tar_target(edc_export_manifest, export_edc(raw_forms, trial_config)),

  # -- Ingest ---------------------------------------------------------------
  # Depends on the export manifest rather than on raw_forms, so that ingest
  # genuinely reads the files off disk in each site's own local conventions
  # instead of quietly reusing the in-memory data that produced them.
  tar_target(ingested, {
    edc_export_manifest
    ingest_exports(trial_config)
  }),

  tar_target(conformed_forms, ingested$forms),
  tar_target(conformance_log, ingested$conformance_log),

  # -- Validation -----------------------------------------------------------
  tar_target(rule_files, list.files("config/rules", full.names = TRUE), format = "file"),
  tar_target(rules, {
    rule_files
    load_rules()
  }),

  tar_target(findings, run_validation(conformed_forms, sites, rules)),

  # -- Scoring the rules against ground truth -------------------------------
  # The rules are only as trustworthy as the evidence that they work, and the
  # only honest evidence is performance against defects we know were injected.
  tar_target(scored_defects, match_defects_to_findings(injected_defects, findings)),
  tar_target(recall_table, recall_by_defect_type(scored_defects)),
  tar_target(recall_summary, recall_overall(scored_defects)),
  tar_target(unmatched_findings, unmatched_findings_by_rule(findings, injected_defects)),

  # -- Derived endpoint -----------------------------------------------------
  # The primary outcome. Derived from the conformed data, never from the
  # simulator's latent truth -- the whole point is that it must cope with the
  # gaps and contradictions the pipeline actually receives.
  tar_target(dawols, derive_days_alive_without_life_support(
    conformed_forms$daily_icu,
    conformed_forms$outcome_30d,
    conformed_forms$randomisation
  )),

  tar_target(dawols_summary, summarise_dawols(dawols)),
  tar_target(dawols_by_domain, summarise_dawols(dawols, by = "domain")),

  # -- Data cut -------------------------------------------------------------
  # A frozen snapshot of everyone who has completed 30-day follow-up as of the
  # cut date, while enrolment continues past them. The Bayesian analysis layer
  # runs on this and never on live data: an analysis run twice on a database
  # that sites are still editing can give two answers, and neither is wrong.
  #
  # Built to the contract in docs/data_cut_sop.md.
  tar_target(cut_as_of_date, as.Date("2025-09-30")),

  tar_target(demonstration_cut, make_cut(
    as_of_date = cut_as_of_date,
    forms = conformed_forms,
    findings = findings,
    endpoint = dawols,
    cfg = trial_config
  )),

  tar_target(cut_verification, verify_cut(demonstration_cut$cut_id)),

  # -- Adaptive analysis ----------------------------------------------------
  # Takes the cut ID and nothing else. Verifies the manifest before reading
  # anything, and applies priors and thresholds pre-specified in config/ and
  # committed before this code existed.
  tar_target(adaptive_analysis, run_adaptive_analysis(demonstration_cut$cut_id)),
  tar_target(analysis_summary, summarise_analysis(adaptive_analysis)),

  # Does the decision survive the choice of prior? The headline is whether the
  # DECISION changes, not what each posterior looks like.
  tar_target(prior_sensitivity_table, prior_sensitivity(demonstration_cut$cut_id)),
  tar_target(decision_robustness_table, decision_robustness(prior_sensitivity_table)),
  tar_target(prior_predictive, prior_predictive_check(load_priors())),

  # -- Monitoring metrics ---------------------------------------------------
  # Computed once here rather than inside each report. Every site report needs
  # the all-site picture to compare against, so recomputing it per report meant
  # doing the same work 25 times and pushed a full render past the five-minute
  # budget in the definition of done.
  tar_target(monthly_completeness, completeness_by_month(conformed_forms)),
  tar_target(monthly_timeliness, timeliness_by_month(conformed_forms, trial_config, sites)),
  tar_target(delay_drift, entry_delay_trend(monthly_timeliness, sites)),
  tar_target(attention_list, sites_needing_attention(findings, dawols, delay_drift, sites)),

  # -- Reporting helpers ----------------------------------------------------
  tar_target(row_counts, form_row_counts(raw_forms)),
  tar_target(defect_summary, defect_catalogue_summary(injected_defects)),
  tar_target(findings_summary, findings_by_rule(findings)),
  tar_target(site_findings, findings_by_site(findings))
)
