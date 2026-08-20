# ADDENDUM to `docs/BUILD_SPEC.md`

> Give this to the agent **after Milestone 1 is merged**. It adds two things:
> Part 1 completes the data management plan; Part 2 adds the Bayesian adaptive
> analysis layer. All hard constraints from section 0 of the original spec still apply —
> synthetic data only, no real institution names, no claim of affiliation.
>
> Append this file to `docs/BUILD_SPEC.md` in the repo before starting work on it.

---

# PART 1 — Complete the data management plan (Milestone 3.5)

The pipeline built in Milestones 1–3 handles data *processing* well. A real trial data
management plan also covers governance, and the repository is currently silent on it.
This part fixes that.

## 1.1 Write the actual plan — `docs/data_management_plan.md`

Produce a versioned, dated DMP document written the way a trial unit would write one, in
these sections. This document is a deliverable in its own right, not a README section.

1. **Scope and version control** — which trial, which domains, DMP version, effective date, change log at the bottom
2. **Roles and responsibilities** — data manager, site investigator, trial registrar, monitor, statistician, sponsor. Who may do what to data.
3. **Data flow** — a diagram (Mermaid, rendered in the doc) from bedside → EDC → export → pipeline → validated dataset → frozen cut → analysis → report
4. **Data sources** — EDC forms, and where applicable external sources
5. **Data dictionary reference** — link to `docs/data_dictionary.md`
6. **Validation approach** — link to `docs/validation_plan.md`, with severity definitions and escalation
7. **Query management** — how queries are raised, routed, escalated, closed; ageing thresholds that trigger escalation
8. **Data cleaning cycles** — routine vs pre-analysis cleaning; what "clean for analysis" means
9. **Database lock and data cuts** — link to `docs/data_cut_sop.md`
10. **Data protection** — section 1.3 below
11. **Retention and archiving** — section 1.5 below
12. **Training and site onboarding** — section 1.6 below
13. **Metrics** — the KPIs the data management function reports on itself

## 1.2 SAE reconciliation (`R/reconcile/`)

Real trials keep serious adverse events in **two places**: the clinical database (entered
by sites on the AE form) and a separate safety/pharmacovigilance record (expedited
reporting). These drift apart, and reconciling them is a core, recurring data management
task.

Implement:

- Simulate a second `safety_db` export with deliberate discrepancies: SAEs present in one
  source and not the other, mismatched onset dates, mismatched seriousness criteria,
  differing outcome coding
- `reconcile_sae()` produces a discrepancy table: `participant_id`, `sae_id`, `field`,
  `clinical_value`, `safety_value`, `discrepancy_type`
- Discrepancies feed the query system like any other finding, at `critical` severity
- A reconciliation section in the central monitoring report

Add a short paragraph to `docs/decisions.md` explaining why SAE reconciliation cannot be
skipped even when both sources "look fine".

## 1.3 Cross-border data protection (`docs/data_protection.md` + `config/countries.yml`)

This is where multi-country actually bites, and it is currently missing entirely.

Model in `config/countries.yml`, per country: legal basis for processing, whether the
country is inside the EEA, whether an adequacy decision applies, the transfer mechanism
required (none / SCCs / other), and the local data-protection contact role.

Then implement:

- A **transfer register**: every dataset movement recorded with source country,
  destination, legal basis, and date
- A pipeline **guard** that refuses to include a site's data in a pooled dataset unless
  that country has an active, non-expired transfer basis recorded in config. Fail loudly.
- At least one country in the config that is **outside the EEA with no adequacy decision**,
  requiring standard contractual clauses — so the guard has something real to do
- Pseudonymisation documented: participant IDs are trial-generated, no national
  identifiers anywhere, no free text, no dates of birth (age in years only)

In `docs/data_protection.md`, explain in plain language why the guard exists: it converts
a compliance obligation into a pipeline behaviour, so a new country cannot be silently
pooled before its paperwork is done.

## 1.4 Role-based access and notification routing (`config/roles.yml`)

Model the EDC role structure: `site_investigator`, `trial_registrar`, `research_nurse`,
`monitor`, `data_manager`, `statistician`. For each role define: which forms are readable,
which are writable, and which notification classes are received (queries, technical
notices, safety alerts).

Then implement a check that flags **over-assignment** — sites where an unusually high
proportion of users hold a notification-bearing role. Over-assignment causes notification
fatigue, which causes queries to be ignored, which is a data quality problem with a
non-technical cause. Surface it in the central report.

## 1.5 Retention, archiving and backup (`docs/retention.md` + `R/archive/`)

- Define retention periods per artefact class (raw exports, frozen cuts, analysis outputs,
  logs) in `config/retention.yml`
- `create_archive_bundle(cut_id)` produces a self-contained, checksummed archive of a cut:
  data, manifest, rule-set version, code commit SHA, rendered reports, and a plain-text
  README explaining how to reproduce it without this repository
- A test that verifies the bundle is complete and its checksums verify

## 1.6 Site onboarding (`docs/site_onboarding.md` + `R/onboarding/`)

A checklist-driven onboarding record per site: initiation date, training completed,
roles assigned, test data submitted and cleared, transfer basis in place.

Implement `check_site_readiness(site_id)` returning a pass/fail per criterion, and make
the pipeline **exclude** data from sites not marked ready. Report exclusions explicitly —
silent exclusion is worse than the problem it solves.

> ### ⏸ CHECKPOINT — Part 1 complete
> Show me `docs/data_management_plan.md` rendered, the SAE discrepancy table, and the
> transfer guard rejecting a country with no valid basis. Open a PR. Wait.

---

# PART 2 — Bayesian adaptive analysis layer (Milestone 4)

## 2.0 The point of this milestone

The analysis must run **on the frozen data cut produced by the data management side** —
never on live or interim data. That seam is the whole point: this milestone demonstrates
the handoff between data management and analysis, and proves the analysis a committee saw
can be regenerated exactly.

Everything here is **pre-specified before it is run**. Write the SAP first, commit it,
then write the code.

## 2.1 Statistical analysis plan — `docs/statistical_analysis_plan.md`

Write and commit this **before any analysis code**. Git history must show the SAP commit
preceding the analysis commits. That ordering is itself the demonstration.

Contents:

- **Analysis populations** — intention-to-treat as primary; define it precisely
- **Primary outcome** — days alive without life support at 30 days (already derived in
  Milestone 1)
- **Secondary outcomes** — 30/90-day mortality; days alive out of hospital at 30 days
- **Statistical model** for each outcome, stated explicitly
- **Priors** — stated as numbers, with the rationale for each. Neutral and weakly
  informative on treatment effects. Explain in one paragraph why the treatment-effect
  prior is centred on no difference, and why the baseline event-rate prior may legitimately
  use existing evidence when the treatment-effect prior may not.
- **Decision thresholds** — pre-specified, in `config/decision_rules.yml`:
  - superiority: P(better) > 0.99
  - inferiority: P(better) < 0.01
  - practical equivalence: P(|mean difference| < 1 day) > 0.90
- **Adaptive analysis schedule** — first analysis when 1,000 participants have completed
  30-day follow-up, then every 250 completed thereafter, to a maximum of 10,000
- **Response-adaptive randomisation** — begins after the first adaptive analysis; minimum
  40% allocation to each arm
- **Sensitivity analyses** — prior sensitivity, and complete-case vs imputed
- **Handling of missing outcome data** — stated, not left implicit

## 2.2 Design simulation with `adaptr` (`R/design/`)

Use the `adaptr` package (CRAN) for design evaluation. Implement, per domain:

- `setup_trial_norm()` or `setup_trial_binom()` matching that domain's outcome type
- `calibrate_trial()` to tune the superiority threshold to an acceptable error rate under
  a null scenario
- `run_trials()` across at least five scenarios: null, small benefit, moderate benefit,
  moderate harm, and one where the arms are practically equivalent
- `check_performance()` and `extract_results()` to produce operating characteristics

Output `reports/design_operating_characteristics.qmd` containing: probability of
conclusiveness, expected sample size, probability of each conclusion type, and the
probability of a wrong conclusion, per scenario. Include `plot_status()` and
`plot_history()` figures.

This document is what justifies the design before the trial opens, and it is the single
most role-relevant artefact in the whole repository.

## 2.3 Interim analysis engine (`R/analyse/`)

`run_adaptive_analysis(cut_id)` — takes a **frozen cut ID**, nothing else. It must:

1. Load the cut and verify its manifest checksums before proceeding. Refuse to run on a
   cut that fails verification.
2. Load pre-specified priors and thresholds from config — never hard-coded in the function
3. Fit the Bayesian model per domain
4. Compute posterior quantities: P(superiority), P(inferiority), P(practical equivalence),
   posterior mean difference with 95% credible interval
5. Apply the decision rules and return a decision per arm: `continue`, `stop_superiority`,
   `stop_inferiority`, `stop_equivalence`
6. Compute updated allocation probabilities under RAR, applying the 40% floor
7. Write a signed analysis record: cut ID, SAP version, rule-set version, priors used,
   package versions, git SHA, timestamp, all results

**Modelling approach:** use conjugate closed-form models where the outcome permits
(beta-binomial for mortality), and `brms` or `rstanarm` for the adjusted continuous model.
Prefer the simplest defensible model. Every modelling choice goes in `docs/decisions.md`
with its rationale. Do not use a complex model you cannot explain in two sentences.

## 2.4 Prior sensitivity and prior predictive checks (`R/analyse/priors.R`)

Two required functions:

- `prior_predictive_check()` — simulate datasets from the priors alone and plot them
  against the range of clinically plausible trial results. If the prior implies implausible
  trials, it is wrong. Include the plot in the analysis report.
- `prior_sensitivity()` — rerun the full decision under at least three prior sets:
  the pre-specified neutral weakly informative prior, a sceptical prior, and a vague prior.
  Produce a table showing the decision under each. **The headline result is whether the
  decision changes.** If it does, that is the finding.

## 2.5 Allocation update and reconciliation (`R/allocate/`)

This closes the loop between analysis and data capture, and it is the most
under-appreciated failure mode in an adaptive platform trial: if allocation probabilities
fail to reach the EDC correctly, nothing errors and no report looks wrong — participants
are simply randomised on the wrong split until someone notices.

Implement:

- `emit_allocation_update(analysis_id)` — writes a versioned, checksummed artefact
  containing the new probabilities, the analysis it came from, and its effective date.
  Never a bare number for a human to retype.
- `reconcile_allocation(period)` — compares the **realised** allocation ratio at each site
  in that period against the ratio that was **specified** to be in force, using a binomial
  test per site, and flags drift
- Deliberately inject a failure in the simulation: one site where the update did not take
  effect. Prove the reconciliation detects it.
- Report reconciliation in the central monitoring report at `critical` severity

## 2.6 Pipeline validation by simulation (`R/analyse/validate_pipeline.R`)

Validate the analysis pipeline itself, not just the design. Simulate complete trials with
a **known true effect**, run them end to end through the real data-management and analysis
code, and check that the decisions the pipeline makes have acceptable error rates.

This distinguishes "the design has good operating characteristics on paper" from "our
implementation of it does". They are not the same claim, and confusing them is a real
failure mode. State this distinction in the README.

## 2.7 Reports

- `reports/adaptive_analysis.qmd` — full internal analysis report for a given cut
- `reports/idmsc_report.qmd` — what an independent data monitoring and safety committee
  would actually receive: enrolment, baseline comparability, primary and secondary
  outcomes by arm, safety summary, the decision under the pre-specified rules, and the
  prior sensitivity table. Written for clinicians, not statisticians.
- Both parameterised by `cut_id`, both recording the cut manifest hash in their footer

## 2.8 The reproducibility proof

Add a test that takes a historical cut ID, reruns the full analysis, and asserts the
results are **bit-identical** to the stored analysis record.

Then put this in the README, prominently:

> Given a cut ID, this repository regenerates the exact interim analysis a committee saw,
> including the data, the priors, the decision, and the report. Here is the test that
> proves it.

That single sentence is the strongest claim the project makes. Make sure it is true.

> ### ⏸ CHECKPOINT — Part 2 complete
> Show me: the design operating characteristics report, one full adaptive analysis run on
> a frozen cut, the prior sensitivity table, the allocation reconciliation detecting the
> injected failure, and the passing reproducibility test. Open a PR. Wait.

---

## Scope warning for the agent

Part 2 is substantial. If time is limited, the priority order is:

1. §2.1 the SAP — cheap, and the pre-specification discipline is the point
2. §2.3 the interim analysis engine running on a frozen cut
3. §2.5 allocation reconciliation
4. §2.2 `adaptr` design simulation
5. §2.4 prior sensitivity
6. §2.6 pipeline validation by simulation

Items 1–3 alone constitute a complete and defensible analysis layer.
