# Design decisions

A dated log of every non-obvious choice made while building this project, with the
reasoning and the alternative that was rejected. Newest entries at the bottom.

---

## 2026-08-20 - DEC-001: `dplyr` rather than `data.table`

**Decision.** The data-manipulation grammar for this repository is `dplyr` (with `tidyr`
for reshaping). Used consistently; no `data.table` anywhere.

**Reasoning.** The specification requires one or the other, consistently. This repository
is written to be *read* - by a hiring panel, and notionally by a trial manager or
clinician checking that a derived endpoint means what they think it means. `dplyr`'s
verb pipeline reads close to prose, which matters more here than throughput. The whole
dataset is ~2,500 participants and well under a million rows, so `data.table`'s
performance advantage is irrelevant at this scale.

**Rejected alternative.** `data.table` - faster and lighter on dependencies, and the
better choice if this pipeline ever had to process tens of millions of rows. Its
`DT[i, j, by]` idiom is denser and less obvious to a reader who does not already know it.
If scale ever became the constraint, the ingest and validate layers are the places to
port first.

---

## 2026-08-20 - DEC-002: Parquet for intermediate storage, CSV only at the EDC boundary

**Decision.** `data/raw/` holds CSV, because that is what a real EDC export looks like
and it is where the messy country-specific formatting problems live. Everything
downstream (`data/interim/`, `data/cuts/`) is Parquet via `arrow`.

**Reasoning.** CSV at the boundary is realistic and is the *point* - date formats,
decimal separators and encodings are only ambiguous because CSV is untyped. Once ingest
has resolved that ambiguity, persisting the resolution in a typed, self-describing
format means no downstream stage can silently re-introduce a coercion bug. Parquet also
hashes stably for the data-cut manifests in Milestone 2.

**Rejected alternative.** RDS - simpler, no `arrow` dependency, but R-only and opaque to
anyone inspecting a frozen cut with other tooling.

---

## 2026-08-20 - DEC-003: Prefer CRAN binaries over newest-version source builds

**Decision.** Package installation requests the newest available *binary* build
(`pkgType = "binary"`), falling back to a source build only where no binary exists for
this platform. Exact resolved versions are pinned in `renv.lock` as normal.

**Reasoning.** The development machine runs R 4.4, which CRAN now classifies as *oldrel*
and no longer builds fresh Windows binaries for. `renv`'s default - take the newest
version on CRAN - therefore silently selects source-only releases and compiles them.
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

## 2026-08-20 - DEC-004: `renv` snapshot type `all`, not the default `implicit`

**Decision.** `renv::settings$snapshot.type("all")`. The lockfile records every package in
the project library, not only those detected in project code.

**Reasoning.** renv's default, `implicit`, builds the lockfile by scanning project `.R`
and `.qmd` files for `library()` / `require()` / `::` calls. At bootstrap there is no code
yet, so the first `renv::snapshot()` produced a lockfile containing exactly one package - 
`renv` itself - despite twelve having been installed. A clean clone running
`renv::restore()` would have installed nothing and the pipeline would have failed at the
first `library()` call. The specification's definition of done (§9) requires
`renv::restore()` on a fresh clone to work, so the lockfile must describe the environment
that was actually tested, independently of whether static analysis can see every usage.

`implicit` also has a subtler failure mode for this project: packages loaded indirectly - 
`arrow` invoked only through a `targets` format declaration, or a Quarto report's engine
dependencies - are easy for the scanner to miss, producing a lockfile that restores an
environment where the pipeline does not actually run.

**Rejected alternative.** Keep `implicit` and rely on code scanning once the R sources
exist. Smaller, tidier lockfiles that document real usage, and it is renv's recommended
default for good reason. Rejected because a lockfile that is silently incomplete is a
reproducibility failure that surfaces only on someone else's machine - precisely the
failure this repository is meant to demonstrate competence against.

**Cost accepted.** The lockfile carries transitive dependencies that could in principle be
pruned (102 packages, ~3,900 lines). It is machine-generated and not read by hand, so the
size is not a real cost.

---

## 2026-08-20 - DEC-005: `alive` is 1 on the day of death, and no daily records follow it

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

## 2026-08-20 - DEC-006: absence of a daily record is not absence of life support

**Decision.** A missing `daily_icu` row means one of two different things, and the
pipeline must distinguish them:

- **Outside a documented ICU stay** - after discharge alive, before readmission - the
  participant is treated as alive and free of life support. The discharge record is
  positive evidence.
- **Inside an ICU stay** - a gap between two days that both have records - the day is
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

## 2026-08-20 - DEC-007: one export file per site per form

**Decision.** The simulated EDC export writes `data/raw/<form>/<site_id>.csv` - 125 files
 - rather than one file per form.

**Reasoning.** Local conventions are a property of the site, not the form. A single
`screening.csv` cannot simultaneously be Latin-1 for DK-03 and UTF-8 for everyone else,
nor carry both `DD-MM-YYYY` and `YYYY-MM-DD` in one column. Per-site files also match how
multi-national trials actually receive data, and they let the ingest conformance log
attribute every transformation to a specific file.

**Rejected alternative.** One file per form with an encoding column. Fewer files, but it
would require the export to already know the answer to the question ingest exists to
answer, which defeats the exercise.

---

## 2026-08-20 - DEC-008: starting and continuing life support are modelled separately

**Decision.** A life-support trajectory is generated from two distinct probabilities:
the probability of *starting* support (logistic in baseline severity, tapering with each
further ICU day) and the probability of *continuing* it once started (a fixed
`persistence` per support type).

**Reasoning.** The first version used a single tapering probability with persistence
folded in as `p + (1 - p) * persistence`. That expression pushes the daily probability
toward 1 as soon as support begins, so in practice nobody ever weaned: renal replacement
ran on 53.6% of all ICU-days against a day-0 rate of 30.5%, and only **5.5%** of ICU-days
were free of all three supports. Days alive without life support would then have been
close to zero for nearly every participant - an endpoint with no variance to detect a
treatment effect in, and one whose few non-zero values would be driven by length of stay
rather than by recovery.

Separating the two probabilities makes episode length geometric with mean
`1 / (1 - persistence)`, which means the parameter is calibrated against something a
clinician can check: how many days a typical episode of that support lasts. The
recalibrated model gives day-0 rates of 63% ventilation, 58% vasopressors and 13.8%
renal replacement, with 21.9% of ICU-days free of all support.

**Rejected alternative.** Keeping one probability and lowering the intercepts until the
marginal rates looked right. It would have matched the day-0 targets while leaving the
duration structure wrong - support would still never stop, just start less often. The
endpoint would still have been degenerate, and the error would have been invisible in any
summary that did not look at episode length.

**Note for the derived endpoint.** This is the generator, not the analysis. The endpoint
in `R/derive/` must not assume any of this structure - it reads the daily records as
given, including their gaps. See DEC-006.

---

## 2026-08-20 - DEC-009: conjugate models and `adaptr`, not Stan

**Decision.** The Bayesian analysis layer (spec Part 2) uses closed-form conjugate models
 - beta-binomial for binary outcomes, normal-normal for the continuous primary endpoint - 
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
- *`rstanarm`* - ships precompiled models, so no runtime compile, and would permit genuine
  covariate adjustment. The right choice if the SAP required an adjusted model with
  partial pooling across sites. It does not.
- *`brms`* - most flexible and most idiomatic for hierarchical models, but compiles each
  model at runtime, which would make CI slow and fragile for no analytical gain here.

**Consequence accepted.** Covariate adjustment is limited to what a conjugate form
supports, i.e. stratified analysis rather than a fitted regression. If the SAP later calls
for an adjusted continuous model with site-level random effects, this decision must be
revisited and `rstanarm` is the fallback. That trigger is recorded here deliberately.

---

## 2026-08-20 - DEC-010: the exported value is the value of record, and conversion is lossy

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
The tolerance is set well below clinical relevance - 0.023 kg is a fortieth of a
kilogram - and the conformance log records every conversion, so the provenance of the
difference is never mysterious.

**Consequence for later milestones.** Data cuts are taken *after* ingest, so the
reproducibility guarantee in Milestone 2 is unaffected: the cut hashes the conformed
values, and re-running ingest on the same raw exports reproduces them exactly. The lossy
step sits upstream of the cut, not inside it.

---

## 2026-08-20 - DEC-011: identifiers are never blanked by the missing-data injector

**Decision.** `blankable_fields()` excludes any field whose name ends in `_id`, in
addition to the record key and `entry_date`.

**Reasoning.** The first version derived blankable fields as "required and not in the
key", which for `daily_icu` - keyed on `participant_id` plus `icu_day` - left
`record_id` eligible. Blanking it produced records with no identifier, which is not a
missing-value defect at all: it is an unlinkable orphan, needing a different rule and a
different remediation. It also broke every downstream ordering silently, which is how it
surfaced - the export/ingest round trip stopped matching because rows could no longer be
aligned by key, and two unrelated fields appeared to be corrupted.

`entry_date` is excluded because the EDC stamps it rather than a human typing it, so it
cannot be blank at entry.

**Worth noting as a general lesson.** The bug was invisible in every summary statistic - 
row counts, defect counts and the conformance log all looked correct. It was only visible
in an invariant test that compared data against itself through a round trip.

---

## 2026-08-20 - DEC-012: endpoint window is days 0-29; death on day 30 is inside it

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

## 2026-08-20 - DEC-013: leaving the ICU is what ends life support, not leaving hospital

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

## 2026-08-20 - DEC-014: the endpoint reports its own completeness

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

---

## 2026-08-20 - DEC-015: monitoring reports are self-contained and rendered in parallel

**Decision.** Every report embeds its own resources (`embed-resources: true`) and the 25
site reports are rendered across four worker processes, each working on its own copy of
the document.

**Reasoning.** Rendered serially, 25 site reports plus the central report took **seven
minutes**, against a five-minute budget for the whole clean-machine run in the
specification's definition of done. Almost all of that time is per-render R startup - 
loading packages and sourcing `R/` - so the work parallelises nearly linearly. Four
workers brought it to **3.6 minutes**.

Self-containment costs about three seconds per report and takes the total to 52 MB, and
is kept anyway for two reasons. A self-contained report is a single file that can be
emailed to a site coordinator, which is how monitoring reports actually reach the people
who act on them. And it avoids parallel renders colliding over a shared supporting-files
directory.

Each worker renders a copy of the document rather than the original: Quarto names its
intermediate working files after the input, so several processes rendering the same
`.qmd` simultaneously overwrite each other and fail. That failure is immediate and loud
rather than subtle, but the fix is worth recording because it is not obvious from the
error message.

**Also moved.** The monthly completeness and timeliness metrics are computed once as
pipeline targets rather than inside each report. Every site report needs the all-site
picture to compare against, so computing it per report meant doing identical work 25
times.

---

## 2026-08-20 - DEC-016: site comparison is normalised by time since initiation

**Decision.** Wherever a site is compared against the others, the horizontal axis is
months since **that site's own initiation**, not calendar time.

**Reasoning.** Sites opened across a 13-month span: 15 Danish sites from January 2024, and
the Dutch, Swedish, Finnish and Icelandic sites from October 2024 onward. On a calendar
axis a site in its second month is set against sites in their twentieth, and the young
site looks worse at everything - fewer participants, less complete follow-up, shorter
history. That comparison is unfair and, worse, useless: everyone already knows the site is
new, so the chart carries no information a coordinator can act on.

Comparing each site against every other site *at the same stage of participation* asks the
question that actually matters: is this site doing worse than others did when they were
this old? The interquartile band across all sites at each month since initiation gives the
reference.

The same normalisation is what makes the entry-delay drift signal legible. SE-02's median
delay rises from 9 days to 26 over 13 months, a slope of 1.69 days per month against 0.18
for the next worst site. On a calendar axis that trend is confounded with the site being
younger than the Danish cohort; against its own initiation it is unmistakable.

---

## 2026-08-21 - DEC-017: cuts include incomplete records, and say so

**Decision.** A participant-domain record enters a data cut when its 30-day window has
closed on or before the as-of date and it has a randomisation datetime to anchor that
window. Whether its data is complete is **not** a criterion. Records with unknown days
enter the cut with an incomplete endpoint and an explicit count, and the manifest reports
how many there are.

**Reasoning.** Excluding participants whose daily records are missing looks like quality
control and is actually selection bias. Data completeness is not randomly distributed: it
correlates with site, site correlates with country, country correlates with case mix and
with local practice. Dropping incomplete records therefore silently reweights the analysis
population toward the sites that enter data well, and those sites differ from the others
in ways that have nothing to do with the treatments being compared.

Including them with the incompleteness visible pushes the decision to where it belongs.
The statistician can run a complete-case sensitivity analysis and see how much it moves
the result, which is a finding. Silent exclusion produces the same numbers with no way to
notice.

**Rejected alternative.** Exclude records with any unknown day, on the grounds that the
endpoint is not measured for them. It would produce a tidier dataset and a smaller,
biased one.

---

## 2026-08-21 - DEC-018: cut files are hashed from disk, after writing

**Decision.** `make_cut()` writes every file, then computes SHA-256 by reading each file
back from disk, then records those hashes in the manifest. The order is not
interchangeable and the hashes are never computed from the in-memory objects.

**Reasoning.** What a later reader verifies is the file. Hashing the in-memory data frame
would produce a value that certifies something nobody can check: it would not detect a
truncated write, a serialisation difference between arrow versions, or a file altered
after the fact. Reading back what was actually written closes that gap, at the cost of one
extra read per file.

The reproduction test deliberately holds the creation timestamp constant, taking it from
the original manifest. Reproduction asks whether the same inputs give the same data, not
whether the clock has moved, and a timestamp inside the compared artefacts would make the
guarantee impossible to satisfy by construction.

**On falsifiability.** The test suite checks that reproduction *fails* when an input is
changed, not only that it succeeds when nothing is. A verification that cannot fail
verifies nothing, and a hash comparison that quietly compares a value against itself would
pass forever while proving nothing at all.

---

## 2026-08-21 - DEC-019: normal approximation for the primary outcome

**Decision.** Days alive without life support is analysed with a normal-normal conjugate
model on the arm means, with the residual standard deviation estimated from the pooled
data and held fixed.

**Reasoning.** The outcome is plainly not normal. It is bounded at 0 and 30, and it is
heavily zero-inflated because every death within the window scores 0 - roughly a third of
participants in this population. A histogram of it looks nothing like a bell.

That does not matter for what the decision rules actually read, which is a **difference in
means** between two arms of several hundred participants each. The sampling distribution of
that difference is well behaved whatever the shape of the underlying outcome, and the
posterior for it is closed-form, deterministic and reproducible in a way no sampler is.
See DEC-009.

Holding the standard deviation fixed rather than integrating over its own prior is the
second simplification. At these sample sizes the uncertainty it contributes to the
difference of means is small relative to the uncertainty in the means themselves.

**What would make this wrong.** A domain with very few participants, where the normal
approximation to the difference has not yet taken hold; or a treatment that changes the
*shape* of the distribution rather than its centre - for example one that converts deaths
into long survivals with prolonged support, moving mass from 0 to the middle without moving
the mean much. The second is a real possibility in critical care, and it is the reason
mortality is analysed separately as its own outcome rather than being trusted to show up in
the primary.

**Rejected alternatives.** A zero-inflated or beta-binomial model on the scaled outcome
would fit the distribution better and would need MCMC, forfeiting exact reproducibility for
a gain the decision rules cannot use. A rank-based comparison avoids distributional
assumptions but does not produce a mean difference, and the equivalence margin is expressed
in days, which a rank statistic cannot speak to.

---

## 2026-08-21 - DEC-020: only the primary outcome may stop a domain

**Decision.** Secondary outcomes - 30-day and 90-day mortality, days alive out of hospital
 - are reported with full posterior quantities but never trigger a stopping decision. Only
days alive without life support does.

**Reasoning.** An adaptive trial's characteristic failure is stopping early on a chance
excursion, and every additional quantity permitted to stop the trial multiplies the
opportunities for that to happen. Three outcomes each tested at P > 0.99 do not give a 1%
error rate; they give something close to three times that, and the inflation is invisible
in any single analysis because each one looks stringent on its own.

Reporting the secondaries costs nothing and informs interpretation. Letting them stop the
trial costs error control.

---

## 2026-08-21 - DEC-021: the SAP is committed before the analysis code

**Decision.** `docs/statistical_analysis_plan.md`, `config/priors.yml` and
`config/decision_rules.yml` are committed in a change that contains **no analysis code at
all**. The engine that reads them arrives in a later commit.

**Reasoning.** Pre-specification is only meaningful if it can be shown to have happened
before the analysis, and in a repository the only evidence that carries any weight is the
commit history. A plan written alongside the code it governs is indistinguishable from a
plan written to match results that were already visible.

Numbers live in `config/` rather than inside functions for the same reason: a committee
member can read the thresholds a decision was made under without reading R, and changing
one is a visible, dated, reviewable act rather than an edit buried in a function body.
Every analysis record stamps the versions of all three files it used, so any result can be
traced to the rules that were in force when it was produced.

**A consequence accepted.** Writing the plan first means committing to decisions before
knowing whether they are convenient to implement. The normal approximation in DEC-019 and
the fixed standard deviation were both chosen partly for tractability, and both are stated
in the plan as assumptions with the conditions that would invalidate them, rather than
being discovered and quietly accommodated later.

---

## 2026-08-21 - DEC-022: the simulator generates no treatment effect, and the first analysis finds one anyway

**Decision.** The synthetic data contains **no treatment effect in any domain**. Arm
allocation is independent of every outcome by construction: the clinical course is
generated from baseline severity alone and never reads the allocated arm. The seed shipped
in `config/trial.yml` is retained even though the first adaptive analysis declares
superiority in ANTICOAG.

**What happened.** Running the pre-specified analysis on `CUT-20250930` gave a difference
of 2.93 days in ANTICOAG, P(better) = 0.9988, crossing the 0.99 superiority threshold and
stopping the domain. Mortality differed by 10 percentage points between arms, 28.3%
against 38.1%.

**Why it is not a bug.** Baseline severity is balanced across the arms, 21.96 against
22.32, so it is not confounding. Repeating the whole simulation under five seeds gives
ANTICOAG differences of -9.3, -4.3, -6.1, +3.7 and -0.2 percentage points: varying in
sign, averaging about -1 point with a standard error of the same magnitude. There is no
systematic association. The shipped seed simply produced a 2.8 sigma excursion, which is
roughly a 1 in 200 event per domain and therefore unsurprising somewhere across three
domains and repeated looks.

**Why the seed is kept.** A demonstration in which the pre-specified rules quietly return
"continue" three times proves very little. This one shows the thing that actually matters
about adaptive designs: **a threshold of P > 0.99 is not a guarantee of truth.** It is a
false positive rate, and here is one. It makes three later pieces of work concrete rather
than theoretical:

- the calibration of the superiority threshold by simulation under a null scenario, which
  is exactly what this dataset is;
- the prior sensitivity analysis, where the question is whether the sceptical prior
  reverses the decision;
- the pipeline validation in the addendum's section 2.6, which measures how often the
  implementation reaches a wrong conclusion when the truth is known.

Reseeding until the answer looked tidy would have hidden the single most instructive result
the analysis layer produces, and would have been a small act of exactly the kind of
selection the whole pre-specification apparatus exists to prevent.

**Consequence to carry forward.** Every report that shows this result must state that the
truth is a null effect and that the finding is therefore a false positive. A reader must
not be left to infer that intermediate-dose anticoagulation works.

**Still to build.** Section 2.6 requires simulating trials with a **known non-zero** effect,
which this generator cannot yet do: the clinical course is produced before allocation is
known. A `true_effect_days` parameter per domain, applied after allocation, is needed for
that milestone. Defaulting it to zero leaves the current dataset unchanged.

---

## 2026-08-21 - DEC-023: the pre-specified prior fails its own predictive check, and is not changed

**Finding.** The prior predictive check required by the analysis plan was run on the
pre-specified prior. Under it:

- **14.4%** of prior-implied arm means fall outside 0 to 30 days, which the outcome cannot
  physically take;
- **48.1%** of prior-implied treatment effects exceed 10 days, larger than any critical
  care intervention has produced for this outcome.

By the standard the analysis plan itself sets, "if the prior implies implausible trials, it
is wrong", the pre-specified Normal(15, 10^2) arm prior is too wide. Called weakly
informative, it is closer to vague on the effect scale.

**Decision. The prior is not changed for this analysis.** Amending a prior after seeing
the result it produced is precisely the manoeuvre the whole pre-specification apparatus
exists to prevent, and it would be no less a manoeuvre for being well intentioned. The
finding is recorded, reported in the analysis outputs, and carried to a future SAP version
as a dated amendment effective for analyses **not yet run**.

**Why nothing hinges on it here.** The sensitivity analysis answers the question directly.
Under the pre-specified prior (SD 10), the sceptical prior (SD 2) and the vague prior
(SD 100), all three domains reach the **same decision**: ANTICOAG stops for superiority,
BUFFER and FLUID continue. The conclusion does not depend on the prior, so an over-wide
prior did not cause the ANTICOAG result.

That is worth stating precisely, because it rules out one explanation and leaves another
standing. The ANTICOAG false positive described in DEC-022 is **not** an artefact of prior
choice. It is a chance imbalance in the data, and no prior in the pre-specified range
suppresses it. A sceptical prior is not a defence against an unlucky sample.

**What a future amendment should say.** An arm prior of Normal(15, 5^2), implying a
treatment-effect prior of about Normal(0, 7^2), keeps 95% of implied effects within
roughly 14 days and puts far less mass outside the outcome's bounds, while remaining weak
enough to be dominated by a few dozen participants per arm. This is recorded as a
recommendation, not applied.

**The general lesson.** The prior predictive check should be run *before* the analysis, not
alongside it. Had it been run when the SAP was written, the prior would have been tightened
then, legitimately and before any data existed. The ordering is now recorded in the plan
for the next version.

---

## 2026-08-21 - DEC-022a: amendment to DEC-022, the threshold is nominal and uncalibrated

**Recorded because DEC-022 blurred two claims that must stay separate.**

**Calibration has not run.** `adaptr::calibrate_trial()` has not been executed, `adaptr` is
not yet a dependency, and section 2.2 of the specification is unbuilt. No target error rate
was set and no calibrated threshold was returned. The **P > 0.99 superiority threshold
shipped in `config/decision_rules.yml` is a nominal default**, taken from the specification
and never checked against a null scenario. Calibration is deferred to section 2.2.

**What the null rate actually is, measured.** Simulating the null scenario through this
repository's own posterior code, 4,000 replicates at 310 per arm with sigma 12.4:

| Quantity | Rate |
|---|---|
| P(stop_superiority given no true difference) | 0.0085 |
| P(stop_inferiority given no true difference) | 0.0090 |
| Any directional stop, per domain per look | 0.0175 |
| At least one stop across 3 domains at 1 look | 0.0516 |

**So the ANTICOAG false positive is bad luck alone.** One directional stop across three
domains at a single look is a 5.2% event under the null. That is unremarkable. It is not
bad luck compounded by an inflated threshold, because only one analysis was performed and
multiplicity across repeated looks never accumulated.

**The uncalibrated threshold is nonetheless a real deficiency, for a different reason.**
The pre-specified schedule performs the first analysis at 1,000 completed participants and
then every 250 thereafter. Under that schedule a domain is examined many times, and a
nominal per-look rate of 1.75% compounds across looks into a substantially larger
probability of stopping a null domain at some point. Nothing in the current results
demonstrates that inflation, because the demonstration ran a single look. But nothing
rules it out either, and the repository must not claim a controlled error rate it has not
measured.

**Therefore:** the design's operating characteristics are **unknown**, not established.
Until `calibrate_trial()` runs under a null scenario and the threshold is tuned to a stated
error rate, no report may describe the error rate as controlled. Section 2.2 is where that
gets fixed, and this entry is the record that it is outstanding.

---

## 2026-08-21 - DEC-023a: amendment to DEC-023, the error was sequencing, not prior choice

**DEC-023 recorded the wrong failure.** It treated an over-wide prior as the problem and
keeping it as the remedy. Keeping it was right, but the prior was a symptom. **The failure
was sequencing.**

A prior predictive check is a condition of a statistical analysis plan becoming effective.
It belongs at finalisation, as a gate. Run afterwards it degrades into a diagnostic, and a
diagnostic is something a person is supposed to notice and act on. Here it was run
alongside the analysis, which is why an obviously defective prior reached a live analysis
at all: 48% of prior mass on treatment effects exceeding 10 days, on an outcome that cannot
exceed 30. Anyone reading that number before the trial opened would have rejected the prior
in seconds. Nothing subtle was missed. It was simply checked at the wrong time.

**The control.** `run_adaptive_analysis()` now refuses to start unless the priors it is
about to use have a **recorded, passing** prior predictive check bound to a hash of the
priors file. It fails on three distinct conditions, reported separately because they call
for different remedies:

- no record exists, so the check was never run;
- the record exists but its hash does not match the priors in force, so a prior was edited
  after the check and the recorded verdict no longer describes it;
- the record matches and records a failure.

The middle condition is the one human review misses most easily and a hash catches
immediately.

**The amendment to the prior itself.** With the gate in place, SAP version 1.0 could not
run: its prior fails both criteria. The plan is therefore amended to **version 1.1**, with
the arm mean prior tightened from Normal(15, 10^2) to Normal(15, 5^2), implying a treatment
effect prior of about Normal(0, 7^2).

This amendment is legitimate at this point in the trial, and the reason is specific rather
than convenient. **A prior predictive check uses no data.** It evaluates a prior against
what is physically and clinically possible, and every input to it existed before a single
participant was enrolled. Tightening a prior in response to it is not a data-dependent
choice, and data dependence is the thing pre-specification exists to prevent. The check
could have been run, and this amendment made, before the trial opened.

Two safeguards against the obvious objection that we amended after seeing a result:

- The decision is unchanged. Under version 1.1 the ANTICOAG probability is 0.9988, the same
  to four figures as under version 1.0, and every domain reaches the same decision. The
  sensitivity analysis had already established invariance across prior standard deviations
  of 2, 10 and 100, a range far wider than this amendment moves within.
- The version 1.0 analysis record is retained unchanged. Both are reported.

**The general principle.** A rule that depends on somebody remembering is not a control. The
prior predictive check, the cut manifest verification, and the transfer guard still to be
built in the data protection work are the same pattern: take an obligation a person is
meant to honour and make it a state the code refuses to proceed without.

---

## 2026-08-24 - DEC-024: allocation reconciliation, and why the injected failure is silent

**Decision.** Defect D13 simulates an interim analysis whose new allocation probabilities
reached every site except one, where the randomisation system silently carried on with the
previous ratio. The injection is built so that **nothing except reconciliation can detect
it**.

**What makes it silent, deliberately.** Three properties, each chosen:

- The `allocation_ratio` field on the failing site's records carries the **new** ratio,
  identical to every other site. That field records the ratio specified to be in force, and
  the specification was issued to everybody. The records are internally consistent.
- The realised split at the failing site is **1:1**, which is an entirely ordinary thing
  for a randomised trial to show. Nothing about the number is suspicious in isolation.
- No validation rule has anything to object to. The records are complete, schema
  conformant, temporally consistent and correctly linked. A row-level rule cannot see the
  problem because the problem is not in any row.

Measured on the pipeline data: the failing site shows 45.9% to the favoured arm against
59.7% at every other site, with the identical `3:2` in the ratio field at both.

**What catches it.** Comparing realised allocation against specified allocation, per site,
by exact binomial test. DK-01 is flagged at p = 8.6e-05; the next most extreme site sits at
p = 0.066, comfortably inside the alpha of 0.01. One site of 25 flagged, and it is the
injected one.

**Why per site and not pooled across sites.** Pooled over the whole trial, one deviating
site is diluted by the twenty-four that applied the update correctly, and the trial-level
ratio looks approximately right. The signal exists only at the level the failure occurred
at.

**Why pooled across domains within a site.** This is a power decision and it cuts the other
way. Per site per domain, the trial randomises only a few dozen participants after an
update, and a 14 point deviation cannot be separated from noise at that size. Pooling a
site's three domains gives roughly 190 randomisations and detects it comfortably. Pooling
is exact only when every domain specifies the same probability for its favoured arm, so
`reconcile_allocation()` checks that and refuses to pool otherwise rather than
approximating quietly: a pooled count over unequal probabilities is Poisson-binomial, not
binomial, and the test would be wrong in a way nothing would reveal.

**A limitation stated rather than hidden.** A small site cannot be flagged on a modest
deviation, and the test suite asserts this. Twelve participants cannot demonstrate a ten
point misallocation. That is correct behaviour: a check that flagged them anyway would be
making an accusation it could not support. The consequence is that this control is weaker
at exactly the sites where a misconfiguration would take longest to notice, and detection
there depends on accumulating more randomisations rather than on a better test.

**Where it surfaces.** Deviations become `ALC-001` findings at `critical` severity, in the
same findings table as everything else, so they travel to the reports through machinery
that already exists rather than through a special case.

---

## 2026-08-26 - DEC-025: the Bayesian analysis layer is removed from scope

**Decision.** This repository covers the **data management** side of the trial only. The
statistical analysis plan, the interim analysis engine, the prior machinery and the design
simulation are removed. The pipeline produces a frozen, verifiable data cut and stops
there.

**What was removed:** `R/analyse/`, `docs/statistical_analysis_plan.md`,
`config/priors.yml`, `config/decision_rules.yml`, `config/prior_predictive_record.yml` and
the 83 tests covering them. The work was implemented and working before it was removed; it
is in the git history up to commit `0ccf9e9` for anyone who wants to read it.

**What stayed, and why it is not analysis.** Two pieces sit close enough to the boundary to
need stating:

- **Data cuts.** Producing a dataset an analysis can run on, and proving that dataset can
  be regenerated exactly a year later, is a data management responsibility. The cut is the
  handover point, not the beginning of the analysis.
- **Allocation reconciliation.** It appears twice in the specification, once as section 3.3
  of Milestone 3 and once inside the analysis addendum. The question it answers is whether
  the allocation that was *specified* actually took effect at each site. That is a question
  about whether data capture did what it was told, and answering it requires no model, no
  prior and no posterior.

**Reasoning.** A complete, coherent project reads better than a larger incomplete one. The
data management work here is finished to a standard: an ingest layer that fails loudly, a
rule engine scored against known defects, an endpoint with forty tests and its
completeness reported alongside it, cuts with a reproducibility proof, and monitoring
reports that lead with what to do. Bolting on a half-built analysis layer would have
weakened that rather than extended it, and a reader would reasonably ask which half was
serious.

**Consequences to be honest about.** Several entries above are now historical rather than
operative, and are kept rather than deleted because a decision log that quietly removes its
own mistakes is worthless:

- **DEC-009** (conjugate models over Stan) and **DEC-019** (the normal approximation)
  described a layer that no longer exists.
- **DEC-020** (only the primary outcome may stop a domain) likewise.
- **DEC-022 and DEC-022a** recorded a false positive found by that layer, and the finding
  that the superiority threshold was never calibrated. The threshold is gone with the
  layer, but the underlying observation stands and is worth keeping: a stopping rule
  quoted as P > 0.99 is a false positive rate, not a guarantee, and this dataset produced
  one.
- **DEC-023a** built a gate refusing to analyse under priors with no recorded passing
  predictive check. The gate is gone. **The pattern it demonstrated is retained elsewhere
  and is the more durable lesson:** an obligation somebody is supposed to remember is not a
  control. `verify_cut()` refusing to return data from an altered cut is the same idea, and
  the transfer guard specified in the data management plan will be a third.

**What the endpoint work is for now.** Days alive without life support remains the derived
endpoint, with its forty tests and its completeness reporting. It is no longer computed in
order to be analysed here; it is computed because deriving a trial's primary outcome
correctly, and reporting how much of it rests on absent data, is a data management
deliverable in its own right.
