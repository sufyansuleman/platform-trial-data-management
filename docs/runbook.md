# Runbook

Operational manual for whoever runs this pipeline. Written to be sufficient on its own: if
you are stuck on something in here, that is a defect in this document, and there is a list
at the bottom of the few things it genuinely cannot answer.

Read [docs/data_management_plan.md](data_management_plan.md) for what the pipeline is
supposed to do and what is not built. This document is how to operate it.

---

## 0. Before you install anything

The monitoring reports this pipeline produces are published at
**<https://sufyansuleman.github.io/platform-trial-data-management/>**, rebuilt by CI from
`main` on every push. You can read the central report and all 25 site reports there without
cloning the repository or installing R, which is the fastest way to see what the pipeline is
for before you start operating it.

Start with the central monitoring report. It is the coordinating centre view: which sites
need attention, how the validation rules actually perform against known defects, and what
the ingest layer had to undo.

## 1. First hour: getting it running

**You need R 4.4.0, Quarto, and on Windows the matching Rtools.** The R version is pinned in
`renv.lock` and matters more than it usually would, for the reason in the next paragraph.

```bash
git clone https://github.com/sufyansuleman/platform-trial-data-management.git
cd platform-trial-data-management
Rscript -e 'renv::restore()'
```

### The one trap, and it will cost you two hours if nobody warns you

**On R 4.4, set the binary preference before you restore.** CRAN classifies R 4.4 as
*oldrel* and no longer builds fresh Windows binaries for it. `renv` defaults to the newest
version on CRAN, which for several packages is now source-only, so `renv::restore()`
silently starts compiling. Measured on the machine this was built on: `igraph` reached 386
of roughly 1,726 object files in thirty minutes, extrapolating to about two hours for a
single dependency of `targets`. `arrow` does the same thing afterwards.

It looks like a hang. It is not. It is a compile, and it is avoidable:

```r
options(pkgType = "binary", install.packages.check.source = "no")
renv::restore()
```

The versions you get are pinned by `renv.lock` either way, so nothing about reproducibility
changes. Only the build time does. The full reasoning is DEC-003 in
[docs/decisions.md](decisions.md).

If you are on R 4.5 or later this does not apply and a plain `renv::restore()` is fine.

### Confirm it works

```bash
Rscript -e 'targets::tar_make()'                      # about 15 seconds
Rscript -e 'testthat::test_dir("tests/testthat")'     # about 30 seconds, expect 419 passing
Rscript scripts/pipeline_summary.R                    # prints what was produced
```

If all three succeed you have a working environment. **Nothing in the repository reads
committed data**: every dataset is regenerated from the seed in `config/trial.yml`, so a
successful run proves the whole chain, not just the last step.

Then, optionally:

```bash
Rscript scripts/render_reports.R           # all 26 reports, about 3.5 minutes
Rscript scripts/render_reports.R DK-01     # one site, for a quick look
```

Output goes to `_site/`. CI publishes the same directory to GitHub Pages from `main`.

---

## 2. The routine cycle

What you do when a new export arrives.

| Step | Command | What you are looking for |
|---|---|---|
| 1. Run it | `targets::tar_make()` | Completes without error. If ingest stops, see section 4. |
| 2. Summarise | `Rscript scripts/pipeline_summary.R` | Finding counts by severity, recall table, conformance log |
| 3. Read the central report | `_site/central_monitoring.html` | Which sites need attention, and why |
| 4. Read the site reports | `_site/site_<SITE>.html` | Each opens with the three things that site should do next |
| 5. Act | Send the queries | Highest severity first, oldest first within severity |

**`targets` only rebuilds what changed.** If you edit one rule file, it re-runs validation
and everything downstream and skips the simulation. `targets::tar_visnetwork()` draws the
dependency graph if you want to see what will run before it does.

### What to look at first, in order

1. **Any `critical` finding.** By definition these affect the analysis population, the
   primary outcome, or a participant's identity. They are escalations, not queries, and per
   the DMP a site cannot close one alone.
2. **Allocation reconciliation.** A flagged site means the specified randomisation ratio
   never took effect there. Nothing else in the pipeline will tell you this, because
   nothing else can: the site's own data looks entirely ordinary. See section 6.
3. **Entry delay trends, not levels.** A site at 9 days median entry delay has a slow
   process. A site that was at 3 days and is now at 9 has something that started recently,
   and that is the more urgent problem even though one number is not worse than the other.
   The monitoring layer compares each site to its own history and to the concurrent
   all-site median, so a Christmas slowdown across every country does not read as
   twenty-five site failures.
4. **Endpoint completeness.** `unknown_days` and `conflicting_days` are reported beside the
   endpoint value. A rising unknown count means data is missing where the endpoint needs
   it, which is a different problem from a rising finding count.

---

## 3. Routine tasks

### Add or change a validation rule

Edit the relevant file in `config/rules/`. No R changes. The rule is an expression that
must be **TRUE for a record to pass**; a record where it is FALSE becomes a finding.

```yaml
- id: RNG-007
  name: platelet_count_plausible
  scope: daily_icu
  severity: major
  description: >
    Platelet count must lie within a physiologically possible range.
  rationale: >
    State why this matters for the trial, not why the number is odd.
  expression: is.na(platelet_count) | (platelet_count >= 1 & platelet_count <= 2000)
  action: query
```

Then:

```bash
Rscript -e 'targets::tar_make()'
Rscript scripts/generate_docs.R    # regenerates docs/validation_plan.md
```

**Guard on `is.na()` where the field can be absent.** A rule that fires on a missing value
duplicates the required-field rule and sends the site two queries for one problem.

**Changing any rule moves the rule set hash**, which is stamped on every finding and in
every cut manifest. That is intended: a finding raised under an older rule set stays
interpretable. Do not renumber existing rule IDs.

### Add or change a field

Edit the form's file in `config/schema/`, then regenerate the docs. The schemas drive four
things at once, which is why this is a single edit and not four:

1. Ingest conforms exports against them
2. `fields: required` in the rule set expands from them
3. `docs/data_dictionary.md` is generated from them
4. The simulator generates values inside their bounds

**One trap:** a description containing a comma must be quoted. These are YAML flow mappings
and an unquoted comma truncates the value silently.

### Take a data cut

```r
cut <- make_cut(as_of_date = as.Date("2025-06-30"))
```

Full procedure, including what the manifest contains and who may do what:
[docs/data_cut_sop.md](data_cut_sop.md).

Before taking one, work through the pre-analysis cleaning checklist in section 8 of the
[data management plan](data_management_plan.md). A cut taken with known open findings is
permitted. A cut taken without stating them is not.

### Verify or reproduce a cut

```r
verify_cut(cut_id)      # recompute every hash against the manifest
reproduce_cut(cut_id)   # regenerate from recorded provenance, assert hash equality
```

`verify_cut()` **refuses** rather than warns. That is deliberate: an integrity check that
can be skipped by somebody in a hurry is not a check.

### Regenerate the documentation

```bash
Rscript scripts/generate_docs.R
```

`docs/data_dictionary.md` and `docs/validation_plan.md` are **generated from `config/`**.
Never edit them by hand; the edit will be silently overwritten and in the meantime the
documentation will disagree with what the pipeline enforces.

---

## 4. When it fails

### Ingest stops with "Ingest failed for ..."

**This is correct behaviour, not a bug.** The ingest layer refuses to coerce anything it
cannot parse under an explicit rule, and it names the site, the field and the offending
values rather than turning them into `NA`. Silent coercion is how a date format change at
one site becomes six months of missing follow-up that nobody noticed.

Work through it in this order:

1. **Read the message.** It names the site, the field and the actual values.
2. **Check the site's locale block** in `config/trial.yml`. Most failures are a site that
   changed its export settings without telling anyone: a new date format, a decimal comma
   where there was a point, or a switch from UTF-8. Site-level keys override the country
   default, which is exactly what this is for.
3. **Encoding is detected from the bytes**, not read from configuration, so an encoding
   change should be handled automatically. If it is not, that is a genuine bug worth
   reporting.
4. **If the values are simply wrong** rather than differently formatted, that is a query to
   the site, not a configuration change. Do not widen a parser to admit bad data.

### A test fails after you changed something

The suite is the specification of the behaviour. Take a failure seriously before assuming
the test is stale. In particular, `test-cut-reproducibility.R` failing means a change has
broken determinism, and that invalidates the strongest guarantee the repository makes.

Things that break cut reproducibility, all recorded in the cut SOP: changing the seed,
changing package versions without re-pinning, and any non-deterministic operation such as
unordered grouping or unseeded sampling.

### The pipeline reruns everything when you expected it not to

`targets` invalidates on file content. Touching `config/trial.yml` invalidates the
simulation and therefore everything. That is correct; it just costs fifteen seconds.

---

## 5. What not to do

- **Do not edit `docs/data_dictionary.md` or `docs/validation_plan.md`.** Generated. Edit
  `config/` and regenerate.
- **Do not commit rendered reports or generated data.** `.gitignore` covers `_site/`,
  `_targets/`, `data/raw/*`, `data/interim/*` and `*.html`. A 2 MB report was committed by
  accident once and had to be removed from the index.
- **Do not change the seed in `config/trial.yml`** unless you intend to invalidate every
  stored cut. Every dataset descends from it.
- **Do not widen a plausibility bound to make a finding go away.** The bounds in
  `config/rules/` are deliberately tighter than the hard bounds in `config/schema/`. The
  first says implausible, the second says impossible, and collapsing them loses the
  distinction the query process runs on.
- **Do not renumber rule IDs.** Findings in circulation reference them.

---

## 6. The failure worth understanding before you start

Most of this pipeline catches problems that announce themselves. One does not, and it is
the reason `R/allocate/` exists.

When new allocation probabilities are decided, they have to reach the EDC and take effect
there. If they do not at one site, **nothing errors**. No exception, no validation finding,
no report looks wrong. The `allocation_ratio` field records what was *specified*, and the
specification went to every site, so the failing site records the same value as everyone
else. Its realised split stays at the previous ratio, which is a perfectly ordinary number
for a randomised trial to show. Participants are simply randomised on the wrong split until
somebody notices.

There is exactly one way to catch it: compare what was **specified** against what was
**realised**, per site, per period. Pooled across all sites the one deviating site is
diluted by every site that applied the update correctly.

```r
result <- reconcile_allocation(randomisation, specified, period_start, period_end)
```

Two properties worth knowing before you read its output:

- **A small site cannot be flagged on a modest deviation.** Twelve participants cannot
  demonstrate a ten point misallocation. This is correct, not a limitation: a test that
  flagged it anyway would generate an accusation it could not support.
- **It refuses to pool domains that specify different probabilities**, because the pooled
  count would be Poisson-binomial rather than binomial and the test would be quietly wrong.
  It errors and tells you to group by domain instead.

The tests in `tests/testthat/test-allocation-reconciliation.R` assert both halves: that
reconciliation catches the failure, and that nothing else does.

---

## 7. Where things are

| Path | What it is |
|---|---|
| `config/trial.yml` | Sites, countries, domains, timeline, clinical model, defect catalogue, seed |
| `config/schema/` | One file per form: columns, types, bounds, required flags |
| `config/rules/` | The validation rules, by category |
| `R/ingest/` | Reading and conforming exports. Fails loudly by design |
| `R/validate/` | The rule engine. Contains no clinical knowledge at all |
| `R/derive/` | The primary endpoint |
| `R/monitor/` | Site metrics and drift detection |
| `R/cut/` | Cuts, manifests, verification, reproduction |
| `R/allocate/` | Allocation updates and reconciliation |
| `R/simulate/` | Synthetic data and defect injection. Drop this if you have real data |
| `_targets.R` | The pipeline DAG |
| `scripts/` | Summary, report rendering, documentation generation |

---

## 8. Reading order for the first day

1. This document, to get it running
2. **[docs/data_management_plan.md](data_management_plan.md)**, for what the pipeline is
   for and, section by section, what is built and what is not
3. **[docs/decisions.md](decisions.md)**, which is the most useful file here. Every
   non-obvious choice with its reasoning and the alternative rejected, including the bugs
   found and what they taught. If something looks strangely specific, the answer is
   probably in here.
4. **[docs/validation_plan.md](validation_plan.md)** and
   **[docs/data_dictionary.md](data_dictionary.md)** when you need them, as reference
5. **[docs/adapting.md](adapting.md)** only if you are pointing this at a different trial

---

## 9. What this documentation cannot answer

Everything operational should be above or in one of the linked documents. These genuinely
require a person:

- **Trial governance decisions.** Whether a cut may be taken with a given finding open,
  whether a deviation is reportable, who signs off a database lock. The plan says what the
  states are; it cannot decide for a specific trial.
- **Priorities among the open scope.** The [data management plan](data_management_plan.md)
  lists the unbuilt work in the order that unblocks the most, but which of it matters for a
  given trial is a decision, not a fact.
- **Anything about the statistical analysis.** Deliberately out of scope. The frozen cut is
  the handover point, and DEC-025 in the decision log explains why the boundary is there.
- **Access and infrastructure.** Repository permissions, CI secrets, where a real EDC export
  would come from.

If something operational is missing here, it is worth fixing this file rather than
answering it once in an email.
