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
  packages = c("yaml", "arrow", "dplyr"),
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

  # -- Reporting helpers ----------------------------------------------------
  tar_target(row_counts, form_row_counts(raw_forms)),
  tar_target(defect_summary, defect_catalogue_summary(injected_defects))
)
