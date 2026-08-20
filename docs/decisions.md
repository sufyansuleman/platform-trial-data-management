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
