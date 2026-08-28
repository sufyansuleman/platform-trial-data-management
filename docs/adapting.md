# Adapting this pipeline to another trial

This repository simulates one trial, but almost none of it knows that. The trial lives in
configuration; the machinery lives in R and does not mention a single clinical concept. If
your trial has sites, forms, fields and rules, most of what is here transfers, and this
document says exactly which parts and what you would change.

It is also an invitation. If you run a trial with a data management problem shaped like
this one, the useful conversation starts here rather than at the beginning.

---

## What is trial-specific and what is not

| Path | Trial-specific? | What you would do |
|---|---|---|
| `config/trial.yml` | **Entirely** | Replace. Sites, countries, domains, timeline, clinical model, defect catalogue |
| `config/schema/*.yml` | **Entirely** | Replace. One file per form |
| `config/rules/*.yml` | **Entirely** | Replace, though the categories usually survive |
| `R/simulate/` | Yes | Replace, or drop entirely if you have real data |
| `R/derive/` | Yes | Replace. Your endpoint is not days alive without life support |
| `R/validate/` | **No** | Keep. No clinical concept appears in it |
| `R/ingest/` | Mostly no | Keep. Add a parser only if you have a format not covered |
| `R/cut/` | **No** | Keep |
| `R/monitor/` | Mostly no | Keep. The metrics are generic; the thresholds are yours |
| `R/allocate/` | Partly | Keep the reconciliation, replace where the specification comes from |
| `reports/` | Partly | Keep the structure, rewrite the prose |
| `_targets.R` | Partly | Edit the targets whose inputs changed |
| `tests/` | Follows the above | Fixtures are trial-specific, the invariants they assert are not |

The short version: **the four `config/` surfaces and two R modules are yours to replace.
The rest is infrastructure.**

---

## Start here: point it at your trial

### 1. `config/trial.yml`

Sites, countries and the clinical process model. The country block is the one people
underestimate, so it is worth looking at first:

```yaml
countries:
  DK:
    name: Denmark
    date_format: "%d-%m-%Y"
    decimal_separator: "."
    weight_unit: kg
    creatinine_unit: umol/L
    encoding: UTF-8
```

Any of those keys can be overridden per site, because in practice one site in a country
will do something different from the rest and nobody will have told you:

```yaml
sites:
  - {id: DK-03, name: "...", country: DK, initiation_date: 2024-01-22, encoding: latin1}
```

Sites carry a `capacity` weight and an `initiation_date`, which is how staggered activation
across countries falls out without special-casing. If your trial activates all sites at
once, give them the same date and the rest of the pipeline does not care.

### 2. `config/schema/*.yml`

One file per form. Each column declares its type, whether it is required, its hard bounds,
its allowed values or its pattern, and a description:

```yaml
form: screening
grain: One row per screened patient.
key: [screening_id]
columns:
  - {name: screening_id, type: character, required: true, pattern: "^SCR-[0-9]{6}$", description: Screening record identifier.}
  - {name: age_years,    type: integer,   required: true, min: 18, max: 120, description: Age at screening.}
  - {name: sex,          type: code,      required: true, allowed: [F, M], description: Recorded sex.}
```

These schemas do four jobs at once, which is why they are worth writing carefully:

1. The ingest layer conforms exports against them
2. The rule engine expands `fields: required` from them, so a required-field rule never
   drifts out of step with the schema
3. `docs/data_dictionary.md` is generated from them, so the dictionary cannot go stale
4. The simulator generates values inside their bounds

**One trap.** A description containing a comma must be quoted. These are YAML flow
mappings, and an unquoted comma truncates the value silently. It cost an afternoon here.

### 3. `config/rules/*.yml`

A rule is an expression that must be **TRUE for a record to pass**. A record where it is
FALSE becomes a finding.

```yaml
- id: TMP-001
  name: discharge_not_before_admission
  scope: outcome_30d
  severity: critical
  description: >
    Hospital discharge must not precede ICU admission.
  rationale: >
    An impossible ordering means one of the two dates is wrong, and length of
    stay derived from them is meaningless until the site says which.
  expression: is.na(hospital_discharge_date) | hospital_discharge_date >= icu_admission_date
  action: query
```

The `is.na()` guard on the left of that expression is the idiom for "this rule has nothing
to say when the field is absent", and it appears throughout the rule set for the reason
given below.

Three things make expressions short:

- **The form's own columns are in scope.** Write `icu_discharge_date`, not
  `data$icu_discharge_date`.
- **Two engine sentinels** cover field-parameterised rules: `.not_missing` is TRUE where
  the check's field has a value, `.in_range` is TRUE where it lies within the min and max
  the rule declares. These are what let one rule cover many fields.
- **Cross-form facts are precomputed as columns** by `build_rule_context()`, so rules read
  as prose rather than as joins. `participant_is_randomised`,
  `days_since_previous_record`, `sites_using_participant_id`,
  `distinct_death_dates_for_participant` and about a dozen others already exist. Adding one
  is a small edit to [R/validate/context.R](../R/validate/context.R), and it is the right
  place to put a join: doing it inside a rule expression would make every rule that needs
  the same fact recompute it.

Two shorthands expand one rule into many checks: `scope` naming several forms runs the rule
once per form, and `fields: required` runs it once per required field in that form's
schema.

**A rule that cannot be evaluated does not fire.** If a rule depends on a field that is
itself missing, it returns nothing, because the missingness is already reported by the
required-field rule and reporting it twice sends the site two queries for one problem. Keep
that property when you write yours.

### 4. `R/derive/`

Replace with your endpoint. The pattern worth keeping is not the calculation, it is what is
returned alongside it: `unknown_days`, `conflicting_days` and a `complete` flag. A value
derived from absent data and a value derived from present data are different numbers and
should not look identical downstream. Everything after the derivation reports completeness
because the derivation hands it over.

---

## If you already have real data

Drop `R/simulate/` and point `ingest_exports()` at your export directory. The pipeline
takes CSV per site per form, which is what most EDC exports look like, and the ingest layer
fails loudly on anything it cannot parse rather than coercing to NA. Expect that first run
to fail several times. That is the layer working.

You lose one thing by dropping the simulator, and it is worth understanding before you do
it: **the recall measurement**. See below.

---

## The part not to skip

The single most transferable idea here is not the rule engine. It is that **the rule engine
is scored against known defects rather than trusted.**

`R/simulate/inject_defects.R` introduces a catalogue of deliberate problems into clean data
and records ground truth for every one. The validation engine then runs blind, and recall
is measured per defect type. The result is a table stating, with numbers, what the rules
catch and what they miss, including three defect types that no rule targets at all and are
reported as `n/a` rather than as zero.

Any validation suite can be made to look good by describing what it checks. Very few can
tell you what fraction of the problems actually present they found. If you adapt one thing
from this repository, adapt that loop: generate clean data, inject known defects with
ground truth, validate, score.

It also pays off in ways you do not plan. A duplicate-participant-identifier defect built
purely to exercise the key checks later surfaced a real bug in a completely different
module, months after it was written. Synthetic defects designed to test one component
become a standing adversarial dataset for every component built afterwards.

---

## What does not generalise

Stated plainly, so you do not discover it yourself.

- **The clinical process model in `config/trial.yml` is ICU-shaped.** Admission, daily
  records, life support, discharge, death. A trial in oncology or primary care keeps the
  structure and replaces the model wholesale.
- **`R/validate/context.R` knows your forms.** It is not clinical, but it is structural: it
  names forms and their date columns. Adding a form means adding it here.
- **The allocation reconciliation assumes randomisation with a specified ratio per domain.**
  It refuses to pool domains whose specified probabilities differ, rather than approximating
  quietly, so it will tell you when it cannot help.
- **The monitoring thresholds are this trial's.** The comparisons, site against its own
  history and against the concurrent all-site median, generalise. The numbers do not.
- **Several things are specified and not built**, and they are listed in priority order at
  the end of [docs/data_management_plan.md](data_management_plan.md). Query management is
  the largest. If you need managed queries on day one, know that going in.

---

## Where to read next

- **[docs/decisions.md](decisions.md)** first, if you only read one. Every non-obvious
  choice with its reasoning and the alternative rejected, including the bugs and what they
  taught. It is the most useful file here for understanding why anything is shaped the way
  it is.
- **[docs/data_management_plan.md](data_management_plan.md)** for the governance frame and
  the honest list of what is not built.
- **[docs/validation_plan.md](validation_plan.md)** and
  **[docs/data_dictionary.md](data_dictionary.md)** are generated from `config/`. Do not
  edit them; edit the configuration and regenerate with `Rscript scripts/generate_docs.R`.
