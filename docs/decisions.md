# Design decisions

A dated log of every non-obvious choice made while building this project, with the
reasoning and the alternative that was rejected. Newest entries at the bottom.

---

## 2026-08-20 — DEC-001: `dplyr` rather than `data.table`

**Decision.** The data-manipulation grammar for this repository is `dplyr` (with `tidyr`
for reshaping). Used consistently; no `data.table` anywhere.

**Reasoning.** The specification requires one or the other, consistently. This repository
is written to be *read* — by a hiring panel, and notionally by a trial manager or
clinician checking that a derived endpoint means what they think it means. `dplyr`'s
verb pipeline reads close to prose, which matters more here than throughput. The whole
dataset is ~2,500 participants and well under a million rows, so `data.table`'s
performance advantage is irrelevant at this scale.

**Rejected alternative.** `data.table` — faster and lighter on dependencies, and the
better choice if this pipeline ever had to process tens of millions of rows. Its
`DT[i, j, by]` idiom is denser and less obvious to a reader who does not already know it.
If scale ever became the constraint, the ingest and validate layers are the places to
port first.

---

## 2026-08-20 — DEC-002: Parquet for intermediate storage, CSV only at the EDC boundary

**Decision.** `data/raw/` holds CSV, because that is what a real EDC export looks like
and it is where the messy country-specific formatting problems live. Everything
downstream (`data/interim/`, `data/cuts/`) is Parquet via `arrow`.

**Reasoning.** CSV at the boundary is realistic and is the *point* — date formats,
decimal separators and encodings are only ambiguous because CSV is untyped. Once ingest
has resolved that ambiguity, persisting the resolution in a typed, self-describing
format means no downstream stage can silently re-introduce a coercion bug. Parquet also
hashes stably for the data-cut manifests in Milestone 2.

**Rejected alternative.** RDS — simpler, no `arrow` dependency, but R-only and opaque to
anyone inspecting a frozen cut with other tooling.

---

## 2026-08-20 — DEC-003: Prefer CRAN binaries over newest-version source builds

**Decision.** Package installation requests the newest available *binary* build
(`pkgType = "binary"`), falling back to a source build only where no binary exists for
this platform. Exact resolved versions are pinned in `renv.lock` as normal.

**Reasoning.** The development machine runs R 4.4, which CRAN now classifies as *oldrel*
and no longer builds fresh Windows binaries for. `renv`'s default — take the newest
version on CRAN — therefore silently selects source-only releases and compiles them.
Measured on this machine, `igraph` 2.3.3 (the newest source release; the R 4.4 binary is
frozen at 2.3.0) reached 386 of ~1,726 object files in 30 minutes, extrapolating to
roughly two hours for one dependency of `targets`. `arrow` would repeat the problem.
Version *recency* buys this project nothing: `igraph` is used only for topological
sorting of the `targets` DAG. Version *pinning* is what the reproducibility requirement
in the specification actually depends on, and `renv.lock` provides that identically for
a binary or a source install.

**Rejected alternatives.**
- *Wait out the source compiles.* Correct but costs hours per environment rebuild, and
  would do the same to anyone cloning the repo on an oldrel R.
- *Upgrade the machine to R 4.5.x*, where every package has a current binary. Cleaner in
  principle, and the right move eventually, but it changes the developer's global
  environment as a side effect of a project setup step, and would require re-running
  `renv::init` against the new R version. Deferred; revisit if a needed package turns out
  to have no 4.4 binary.

**Consequence to watch.** CI runs on a different R version than local development. The
GitHub Actions workflow restores from `renv.lock`, so versions match; if a pinned version
has no binary on the runner, CI absorbs a one-off compile. Acceptable, and cached.

---

## 2026-08-20 — DEC-004: `renv` snapshot type `all`, not the default `implicit`

**Decision.** `renv::settings$snapshot.type("all")`. The lockfile records every package in
the project library, not only those detected in project code.

**Reasoning.** renv's default, `implicit`, builds the lockfile by scanning project `.R`
and `.qmd` files for `library()` / `require()` / `::` calls. At bootstrap there is no code
yet, so the first `renv::snapshot()` produced a lockfile containing exactly one package —
`renv` itself — despite twelve having been installed. A clean clone running
`renv::restore()` would have installed nothing and the pipeline would have failed at the
first `library()` call. The specification's definition of done (§9) requires
`renv::restore()` on a fresh clone to work, so the lockfile must describe the environment
that was actually tested, independently of whether static analysis can see every usage.

`implicit` also has a subtler failure mode for this project: packages loaded indirectly —
`arrow` invoked only through a `targets` format declaration, or a Quarto report's engine
dependencies — are easy for the scanner to miss, producing a lockfile that restores an
environment where the pipeline does not actually run.

**Rejected alternative.** Keep `implicit` and rely on code scanning once the R sources
exist. Smaller, tidier lockfiles that document real usage, and it is renv's recommended
default for good reason. Rejected because a lockfile that is silently incomplete is a
reproducibility failure that surfaces only on someone else's machine — precisely the
failure this repository is meant to demonstrate competence against.

**Cost accepted.** The lockfile carries transitive dependencies that could in principle be
pruned (102 packages, ~3,900 lines). It is machine-generated and not read by hand, so the
size is not a real cost.

---

## 2026-08-20 — DEC-005: `alive` is 1 on the day of death, and no daily records follow it

**Decision.** In `daily_icu`, `alive = 1` on the calendar day the participant died,
because they were alive for part of it. No daily record exists for any day after the
date of death.

**Reasoning.** The daily record describes a day, not an instant, and every day in the ICU
except the last is unambiguous. Encoding the death day as `alive = 0` would make the
record claim the participant was dead for the whole day, which contradicts the
observations (ventilation, vasopressors) recorded on that same row. The rule that then
becomes checkable is a clean one: any record with `alive = 1` dated strictly after
`death_date` is a contradiction. That is rule LOG-002, and defect D08 exists to test it.

**Rejected alternative.** `alive = 0` on the death day, treating the flag as end-of-day
status. Equally defensible, and some EDC systems do it, but it makes the day of death
indistinguishable from the day after in any rule that does not also read `death_date`.

---

## 2026-08-20 — DEC-006: absence of a daily record is not absence of life support

**Decision.** A missing `daily_icu` row means one of two different things, and the
pipeline must distinguish them:

- **Outside a documented ICU stay** — after discharge alive, before readmission — the
  participant is treated as alive and free of life support. The discharge record is
  positive evidence.
- **Inside an ICU stay** — a gap between two days that both have records — the day is
  **unknown**, not "free of support".

**Reasoning.** This is the single most consequential convention in the repository, which
is why defect D02 injects interior gaps specifically. Defaulting a gap to "free of
support" silently inflates days alive without life support, and that number is what an
adaptive stopping decision reads. An endpoint that drifts upward in proportion to how
badly a site enters its data is not a clinical signal, it is a data-quality artefact
wearing a clinical signal's clothes. Defaulting it to "on support" is the opposite bias
and equally wrong.

Treating interior gaps as unknown means the derived endpoint must return a missingness
indicator alongside the count, so that an analyst can see how much of the estimate rests
on absent data rather than being handed a single confident-looking integer.

**Rejected alternatives.**
- *Impute the gap by carrying the previous day forward.* Plausible for physiology,
  indefensible for an endpoint: it manufactures the very observations the endpoint counts.
- *Treat all absence as free of support.* Simple, and wrong in the direction that
  flatters bad data.

---

## 2026-08-20 — DEC-007: one export file per site per form

**Decision.** The simulated EDC export writes `data/raw/<form>/<site_id>.csv` — 125 files
— rather than one file per form.

**Reasoning.** Local conventions are a property of the site, not the form. A single
`screening.csv` cannot simultaneously be Latin-1 for DK-03 and UTF-8 for everyone else,
nor carry both `DD-MM-YYYY` and `YYYY-MM-DD` in one column. Per-site files also match how
multi-national trials actually receive data, and they let the ingest conformance log
attribute every transformation to a specific file.

**Rejected alternative.** One file per form with an encoding column. Fewer files, but it
would require the export to already know the answer to the question ingest exists to
answer, which defeats the exercise.

---

## 2026-08-20 — DEC-008: starting and continuing life support are modelled separately

**Decision.** A life-support trajectory is generated from two distinct probabilities:
the probability of *starting* support (logistic in baseline severity, tapering with each
further ICU day) and the probability of *continuing* it once started (a fixed
`persistence` per support type).

**Reasoning.** The first version used a single tapering probability with persistence
folded in as `p + (1 - p) * persistence`. That expression pushes the daily probability
toward 1 as soon as support begins, so in practice nobody ever weaned: renal replacement
ran on 53.6% of all ICU-days against a day-0 rate of 30.5%, and only **5.5%** of ICU-days
were free of all three supports. Days alive without life support would then have been
close to zero for nearly every participant — an endpoint with no variance to detect a
treatment effect in, and one whose few non-zero values would be driven by length of stay
rather than by recovery.

Separating the two probabilities makes episode length geometric with mean
`1 / (1 - persistence)`, which means the parameter is calibrated against something a
clinician can check: how many days a typical episode of that support lasts. The
recalibrated model gives day-0 rates of 63% ventilation, 58% vasopressors and 13.8%
renal replacement, with 21.9% of ICU-days free of all support.

**Rejected alternative.** Keeping one probability and lowering the intercepts until the
marginal rates looked right. It would have matched the day-0 targets while leaving the
duration structure wrong — support would still never stop, just start less often. The
endpoint would still have been degenerate, and the error would have been invisible in any
summary that did not look at episode length.

**Note for the derived endpoint.** This is the generator, not the analysis. The endpoint
in `R/derive/` must not assume any of this structure — it reads the daily records as
given, including their gaps. See DEC-006.

---

## 2026-08-20 — DEC-009: conjugate models and `adaptr`, not Stan

**Decision.** The Bayesian analysis layer (spec Part 2) uses closed-form conjugate models
— beta-binomial for binary outcomes, normal-normal for the continuous primary endpoint —
with `adaptr` for design operating characteristics. Neither `brms` nor `rstanarm` is a
dependency.

**Reasoning.** The specification asks for the simplest defensible model and says
explicitly not to use a complex model that cannot be explained in two sentences. A
conjugate beta-binomial posterior meets that test exactly: the posterior is
`Beta(a + events, b + non-events)`, and P(superiority) is a single integral over two
independent posteriors evaluated by direct draws. There is nothing to diagnose, nothing to
converge, and no sampler seed to make the result irreproducible.

That last point decides it. Spec §2.8 requires a test asserting a rerun analysis is
**bit-identical** to the stored analysis record. An MCMC sampler makes that claim fragile:
it holds only for a fixed seed, a fixed chain count, and a fixed version of the sampler
and its compiler. A conjugate posterior is a deterministic function of the sufficient
statistics, so bit-identity is a property of the arithmetic rather than a property of the
environment. The strongest claim the repository makes should not rest on a Stan toolchain
being byte-stable across machines.

Runtime matters too: `rstan` compiles models with Rtools, and the definition of done
requires a clean run in under five minutes with CI on every push.

**Rejected alternatives.**
- *`rstanarm`* — ships precompiled models, so no runtime compile, and would permit genuine
  covariate adjustment. The right choice if the SAP required an adjusted model with
  partial pooling across sites. It does not.
- *`brms`* — most flexible and most idiomatic for hierarchical models, but compiles each
  model at runtime, which would make CI slow and fragile for no analytical gain here.

**Consequence accepted.** Covariate adjustment is limited to what a conjugate form
supports, i.e. stratified analysis rather than a fitted regression. If the SAP later calls
for an adjusted continuous model with site-level random effects, this decision must be
revisited and `rstanarm` is the fallback. That trigger is recorded here deliberately.

---

## 2026-08-20 — DEC-010: the exported value is the value of record, and conversion is lossy

**Decision.** After ingest, the value of record is the value that came out of the site's
export, converted to internal units. The pre-export value inside the simulator is not
recoverable exactly, and the pipeline does not pretend otherwise. Round-trip tests assert
agreement within a stated tolerance, not bit equality.

**Reasoning.** DK-07 exports weight in pounds to one decimal place and NL-01 exports
creatinine in mg/dL to two. Converting those back to kg and umol/L cannot recover more
precision than the export carried: the round trip differs by up to 0.023 kg and
0.44 umol/L respectively. This is not a defect to be fixed by widening the export format.
It is what actually happens when a site records a value in its own units at its own
precision, and the exported figure is the one the site can attest to.

Asserting bit equality would therefore be asserting something false about the data flow.
The tolerance is set well below clinical relevance — 0.023 kg is a fortieth of a
kilogram — and the conformance log records every conversion, so the provenance of the
difference is never mysterious.

**Consequence for later milestones.** Data cuts are taken *after* ingest, so the
reproducibility guarantee in Milestone 2 is unaffected: the cut hashes the conformed
values, and re-running ingest on the same raw exports reproduces them exactly. The lossy
step sits upstream of the cut, not inside it.

---

## 2026-08-20 — DEC-011: identifiers are never blanked by the missing-data injector

**Decision.** `blankable_fields()` excludes any field whose name ends in `_id`, in
addition to the record key and `entry_date`.

**Reasoning.** The first version derived blankable fields as "required and not in the
key", which for `daily_icu` — keyed on `participant_id` plus `icu_day` — left
`record_id` eligible. Blanking it produced records with no identifier, which is not a
missing-value defect at all: it is an unlinkable orphan, needing a different rule and a
different remediation. It also broke every downstream ordering silently, which is how it
surfaced — the export/ingest round trip stopped matching because rows could no longer be
aligned by key, and two unrelated fields appeared to be corrupted.

`entry_date` is excluded because the EDC stamps it rather than a human typing it, so it
cannot be blank at entry.

**Worth noting as a general lesson.** The bug was invisible in every summary statistic —
row counts, defect counts and the conformance log all looked correct. It was only visible
in an invariant test that compared data against itself through a round trip.

---

## 2026-08-20 — DEC-012: endpoint window is days 0-29; death on day 30 is inside it

**Decision.** Days alive without life support counts days 0 to 29 inclusive, where day 0
is the day of randomisation into *that domain*. Death on or before day 30 scores 0; death
on day 31 does not.

**Reasoning.** "Within 30 days" has two readings that differ by exactly one day, and
leaving the choice implicit means the code and the analysis plan can silently disagree
about it. Thirty days beginning on the day of randomisation is days 0 to 29. Vital status,
by contrast, is assessed *at* 30 days, so a death on day 30 falls inside the assessment
and zeroes the endpoint even though day 30 is not itself counted. Both boundaries are
tested explicitly at days 0, 1, 29, 30 and 31.

Each domain is anchored to its own randomisation. A participant entered into two domains
two days apart has two windows that overlap but do not coincide, and scoring both against
the first randomisation would mis-score the second. This is tested directly.

---

## 2026-08-20 — DEC-013: leaving the ICU is what ends life support, not leaving hospital

**Decision.** A day with no ICU record counts as alive and free of life support when it
falls after the participant's last ICU record, or after a documented hospital discharge.
A missing day interior to the recorded ICU stay remains unknown.

**Reasoning.** The first implementation credited only days after *hospital* discharge. But
life support in this trial -- invasive ventilation, vasopressors, renal replacement -- is
delivered in an ICU. A participant discharged from the ICU on day 2 and from hospital on
day 12 spent days 3 to 11 on a general ward: alive, and by definition not receiving any of
the three. Treating those as unknown discarded real information.

The consequence was severe and was invisible in the unit tests. On pipeline data, **68% of
surviving participants were marked incomplete** and total unknown days stood at 12,440.
After the correction, unknown days fell to 1,608 and complete records rose from 990 to
2,233. Every one of the original 26 endpoint tests passed both before and after, because
every fixture happened to discharge from ICU and hospital on the same day. A regression
test for the ward-day case has been added.

Both conditions are needed, not either alone. The hospital-discharge condition is what
covers the days between an ICU discharge and a later readmission, where the participant
returns to an ICU so the last-record condition does not apply.

**What this does not license.** A gap *between* two ICU records is still unknown. Leaving
the ICU explains the days after it; it does not retrospectively explain a gap inside the
stay. That distinction is tested.

---

## 2026-08-20 — DEC-014: the endpoint reports its own completeness

**Decision.** `derive_days_alive_without_life_support()` returns `unknown_days`,
`conflicting_days` and `complete` alongside the count, and `summarise_dawols()` reports
the mean over all records and over complete records separately.

**Reasoning.** A single integer looks equally confident whether it rests on thirty
observed days or on twenty observed days and ten absent ones. An analyst has to be able to
see the difference. On current pipeline data the two means differ by **1.6 days**
(16.18 against 14.55), which is larger than the 1-day practical-equivalence margin the
analysis plan uses to declare two arms equivalent. A difference that can move a
pre-specified decision cannot be left implicit in a footnote.

Records with no randomisation date have no window to score and return NA rather than 0.
Returning 0 would silently score them as the worst possible outcome; NA forces them to be
counted and reported as not evaluable, which on current data is 99 of 3,058 records.

**Rejected alternative.** Impute the unknown days from surrounding days. It would produce
a complete-looking dataset whose completeness is manufactured, and it would remove the one
signal that tells a coordinator which site to call.
