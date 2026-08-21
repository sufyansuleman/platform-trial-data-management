# Validation plan

> **Generated file.** Produced by `scripts/generate_docs.R` from `config/`. Edit the configuration, not this file. Last generated 21 August 2026.

This document is the standard operating procedure for data validation: what
is checked, why it is checked, how serious a failure is, and what happens
when one occurs.

## How validation works here

**The engine is generic; the rules are data.** No R code knows what a
vasopressor is or that discharge follows admission. Every check lives in
`config/rules/*.yml` as an expression, a severity, a description and a
rationale. A clinician or trial manager can read the entire rule set, and
propose a new rule, without reading any R.

**The output is a findings dataset, not a pass or fail.** The purpose of
validation is to tell somebody what to fix. Each finding carries the site,
the participant, the form, the field and the observed value, so it can be
acted on rather than merely counted.

**A rule that cannot be evaluated does not fire.** If a rule depends on a
field that is itself missing, it returns no finding: the missingness is
already reported by STR-001, and reporting it twice would send the site two
queries for one problem.

**The rule set is versioned.** Every finding records a hash of the rule
files that produced it, so a finding raised a year ago remains interpretable
after the rules have changed.

The current rule set is `455d0fba76e0` and contains **23 rules**.

## Severity and what happens when a rule fires

Severity describes the consequence for the trial, not the difficulty of
fixing the problem. It determines how quickly somebody has to act.

| Severity | Meaning | Response |
|---|---|---|
| `critical` | The analysis population, the primary outcome or a participant's identity is affected. The finding makes some part of the dataset unusable until resolved. | Escalated to the coordinating centre the same working day. Not closed by the site alone. |
| `major` | A required value is absent or implausible. The record is usable but incomplete or suspect. | Query raised with the site. Expected turnaround 14 days. |
| `minor` | A value that supports interpretation is missing but no analysis depends on it. | Query raised, batched with the site's next routine contact. |
| `informational` | Recorded for monitoring purposes; no site action expected. | Reported in the central monitoring report only. |

The `action` field on each rule states which of these applies:
`query` raises a query with the site, `escalate` also notifies the
coordinating centre.

## How the rules are known to work

The pipeline injects a catalogue of known defects into the synthetic data
and records ground truth for every one. The validation engine is then scored
against that catalogue, so its performance is measured rather than asserted,
and the rules it misses are reported alongside the ones it catches. The
current figures are in the README and in the central monitoring report.

Three injected defect types have no rule in this rule set: entry-delay
drift, terminal-digit preference and adverse-event under-reporting. None of
them can be detected in a single record — every individual record is valid —
and they are addressed by statistical monitoring instead. They are reported
as not applicable rather than as failures, because scoring a rule set
against defects it was never written to catch would misrepresent it.

## The rules

### Structural — types, keys, required fields, referential integrity

Defined in `config/rules/structural.yml`.

#### STR-001 — required field present

| | |
|---|---|
| **Applies to** | `screening`, `randomisation`, `daily_icu`, `outcome_30d`, `adverse_events` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `.not_missing` |

**What it checks.** Every field marked required in the form schema must carry a value.

**Why it matters.** A required field is required because downstream analysis cannot proceed without it. Missingness concentrated at one site is a training or workload problem at that site, not a random accident, which is why the finding carries the site.

#### STR-002 — participant known to randomisation

| | |
|---|---|
| **Applies to** | `daily_icu`, `outcome_30d`, `adverse_events` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `participant_is_randomised` |

**What it checks.** Every participant referenced by a follow-up form must have at least one randomisation record.

**Why it matters.** A follow-up record for a participant who was never randomised means either the randomisation record is missing or the record belongs to someone else. Both are serious: the first loses a participant from the analysis, the second attributes data to the wrong person.

#### STR-003 — participant id unique to one site

| | |
|---|---|
| **Applies to** | `screening` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `sites_using_participant_id <= 1` |

**What it checks.** A participant identifier must be used at exactly one site.

**Why it matters.** An identifier issued at two sites collapses two people into one record in every join downstream. Nothing errors; the analysis simply describes a person who does not exist.

#### STR-004 — single randomisation per domain

| | |
|---|---|
| **Applies to** | `randomisation` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `randomisations_in_domain <= 1` |

**What it checks.** A participant must be randomised at most once within any single domain.

**Why it matters.** A second allocation in the same domain means the participant may have received both interventions, or that one allocation was never acted on. Either way the analysis population is ambiguous and the site must say which allocation was followed.

### Range — physiological plausibility

Defined in `config/rules/range.yml`.

#### RNG-001 — weight plausible

| | |
|---|---|
| **Applies to** | `screening` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `.in_range` |

**What it checks.** Body weight must lie within the plausible adult range, 35 to 160 kg. Bounds: 35 to 160.

**Why it matters.** Values above the plausible maximum are most often a units failure -- a pounds reading submitted as kilograms is roughly 2.2 times too high, which lands a typical adult above 160 kg. Values below it suggest a paediatric record or a transposition. Both warrant confirmation rather than deletion.

#### RNG-002 — heart rate plausible

| | |
|---|---|
| **Applies to** | `daily_icu` |
| **Severity** | `critical` |
| **Action** | `query` |
| **Expression** | `.in_range` |

**What it checks.** Heart rate must lie between 25 and 220 beats per minute. Bounds: 25 to 220.

**Why it matters.** A sustained rate outside this range is incompatible with a patient who is recorded as alive on the same record. This is an entry error, not a physiological finding.

#### RNG-003 — temperature plausible

| | |
|---|---|
| **Applies to** | `daily_icu` |
| **Severity** | `critical` |
| **Action** | `query` |
| **Expression** | `.in_range` |

**What it checks.** Core temperature must lie between 30 and 43 degrees Celsius. Bounds: 30 to 43.

**Why it matters.** Values outside this range are almost always a unit confusion or a decimal slip. Genuine extremes of temperature are documented in the clinical record and confirmed on query rather than assumed from a single entry.

#### RNG-004 — creatinine plausible

| | |
|---|---|
| **Applies to** | `screening` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `.in_range` |

**What it checks.** Serum creatinine must lie between 15 and 1200 umol/L. Bounds: 15 to 1200.

**Why it matters.** The upper bound admits severe untreated renal failure, which this population genuinely contains. A value above it, or an implausibly low one, more often indicates a mg/dL reading submitted as umol/L or the reverse.

#### RNG-005 — age plausible

| | |
|---|---|
| **Applies to** | `screening` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `.in_range` |

**What it checks.** Age must be at least 18, the trial's lower eligibility limit, and below 110. Bounds: 18 to 110.

**Why it matters.** An age below 18 is an eligibility violation as well as a data problem and must be escalated, not merely queried at the site.

#### RNG-006 — severity score plausible

| | |
|---|---|
| **Applies to** | `screening` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `.in_range` |

**What it checks.** The severity index must lie on its defined 0 to 71 scale. Bounds: 0 to 71.

**Why it matters.** A value off the scale means the wrong instrument was recorded, which invalidates any case-mix adjustment that uses it.

### Logic — cross-field and cross-form consistency

Defined in `config/rules/logic.yml`.

#### LOG-001 — no gap in daily records

| | |
|---|---|
| **Applies to** | `daily_icu` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `days_since_previous_record <= 1` |

**What it checks.** Consecutive daily records for a participant must not skip a day within an ICU stay.

**Why it matters.** A missing day inside a stay is not the same as a discharge. Until it is resolved, the day is unknown, and the primary endpoint must treat it as unknown rather than as a day free of life support. Defaulting a gap to "no support recorded" inflates days alive without life support in proportion to how badly a site enters data, which turns a data-quality problem into an apparent treatment effect.

#### LOG-002 — not alive after death

| | |
|---|---|
| **Applies to** | `daily_icu` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `record_date <= death_date_or_infinity` |

**What it checks.** A daily record must not report the participant alive on a date after the recorded date of death.

**Why it matters.** The contradiction spans two forms, so neither form looks wrong on its own. One of the two is incorrect and the site must say which: the outcome form drives the primary analysis, and the daily records drive the endpoint.

#### LOG-003 — death date requires dead status

| | |
|---|---|
| **Applies to** | `outcome_30d` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `death_date_and_status_agree` |

**What it checks.** A record carrying a date of death must report vital status as dead, and a record reporting death must carry a date.

**Why it matters.** Vital status is the secondary outcome and the gate on the primary one. A status and a date that disagree make the participant's contribution to the analysis undefined.

#### LOG-004 — life support requires alive

| | |
|---|---|
| **Applies to** | `daily_icu` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `alive == 1 | (mechanical_ventilation == 0 & vasopressors == 0 & renal_replacement == 0)` |

**What it checks.** Life support must not be recorded on a day the participant is reported as not alive.

**Why it matters.** Support delivered to a participant recorded as dead on the same row is an internal contradiction within a single record, and the most likely explanation is that the alive flag was mis-entered rather than that the support was.

#### LOG-005 — icu location present when in icu

| | |
|---|---|
| **Applies to** | `daily_icu` |
| **Severity** | `minor` |
| **Action** | `query` |
| **Expression** | `in_icu == 0 | !is.na(icu_location)` |

**What it checks.** A record marked as in ICU must name the ICU unit.

**Why it matters.** The unit identifier is what makes a mid-stay transfer visible. Without it, a participant who moved between units is indistinguishable from one who did not, and transfers are a known source of duplicated daily records.

### Temporal — date sequencing

Defined in `config/rules/temporal.yml`.

#### TMP-001 — discharge not before admission

| | |
|---|---|
| **Applies to** | `outcome_30d` |
| **Severity** | `critical` |
| **Action** | `query` |
| **Expression** | `is.na(hospital_discharge_date) | hospital_discharge_date >= icu_admission_date` |

**What it checks.** Hospital discharge must not precede ICU admission.

**Why it matters.** An impossible ordering means one of the two dates is wrong, and length of stay derived from them is meaningless until the site says which.

#### TMP-002 — death not before randomisation

| | |
|---|---|
| **Applies to** | `outcome_30d` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `is.na(death_date) | death_date >= first_randomisation_date` |

**What it checks.** Date of death must not precede the participant's first randomisation.

**Why it matters.** A death before allocation means the participant was never eligible to be randomised, or the death date belongs to a different record. Either invalidates the participant's contribution to the primary outcome.

#### TMP-003 — entry not before event

| | |
|---|---|
| **Applies to** | `screening`, `randomisation`, `daily_icu`, `outcome_30d`, `adverse_events` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `entry_not_before_event` |

**What it checks.** A record cannot be entered into the EDC before the event it describes.

**Why it matters.** Entry before the event indicates a mistyped event date or a record completed in advance. Records completed in advance are a documented route to fabricated observations and must be queried, not silently accepted.

#### TMP-004 — ae onset before randomisation

| | |
|---|---|
| **Applies to** | `adverse_events` |
| **Severity** | `critical` |
| **Action** | `query` |
| **Expression** | `onset_date >= first_randomisation_date` |

**What it checks.** Adverse event onset must not precede the participant's first randomisation datetime in any domain.

**Why it matters.** An AE preceding randomisation is not attributable to the trial intervention and indicates a data entry or linkage error.

#### TMP-005 — screening not after randomisation

| | |
|---|---|
| **Applies to** | `randomisation` |
| **Severity** | `major` |
| **Action** | `escalate` |
| **Expression** | `is.na(screening_date_for_participant) | as.Date(randomisation_datetime) >= screening_date_for_participant` |

**What it checks.** Randomisation must not precede the screening assessment that established eligibility.

**Why it matters.** Allocation before eligibility was confirmed is a protocol deviation as well as a data problem, and is reportable as such.

### Cross-domain — participants entered in more than one domain

Defined in `config/rules/cross_domain.yml`.

#### XDM-001 — death date consistent across domains

| | |
|---|---|
| **Applies to** | `outcome_30d` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `distinct_death_dates_for_participant <= 1` |

**What it checks.** A participant entered in more than one domain must have the same date of death recorded in every domain.

**Why it matters.** A person dies once. Two domains reporting different death dates means at least one primary outcome is wrong, and because each domain is analysed separately the error would otherwise never surface.

#### XDM-002 — icu admission consistent across domains

| | |
|---|---|
| **Applies to** | `outcome_30d` |
| **Severity** | `major` |
| **Action** | `query` |
| **Expression** | `distinct_admission_dates_for_participant <= 1` |

**What it checks.** ICU admission date must agree across every domain a participant is entered in.

**Why it matters.** Admission anchors length of stay and the daily record timeline. Domains disagreeing about it means the same daily records are being interpreted against two different day-zero definitions.

#### XDM-003 — vital status consistent where windows agree

| | |
|---|---|
| **Applies to** | `outcome_30d` |
| **Severity** | `critical` |
| **Action** | `escalate` |
| **Expression** | `vital_status_consistent_at_shared_window` |

**What it checks.** Where two domains share the same 30-day assessment date, they must report the same vital status.

**Why it matters.** Domains anchored to different randomisation dates may legitimately differ on 30-day status, because the windows genuinely end on different days. Where the windows end on the SAME day, any disagreement is an error. This rule is deliberately narrow so that legitimate differences are not reported as findings.

## Vocabulary available to rule authors

Rule expressions may use any field on the form they are scoped to, plus the
derived context columns below. These exist so that a rule needing a fact
from another form stays readable as prose rather than becoming a join.
They are computed in `R/validate/context.R`.

| Column | Available on | Meaning |
|---|---|---|
| `first_randomisation_date` | `outcome_30d`, `adverse_events` | Earliest randomisation across all domains for this participant. |
| `domain_randomisation_date` | `outcome_30d` | Randomisation date for *this* domain. |
| `window_end_date` | `outcome_30d` | Thirty days after this domain's randomisation. |
| `participant_is_randomised` | follow-up forms | Whether the participant has any randomisation record. |
| `sites_using_participant_id` | `screening` | Number of distinct sites using this identifier. |
| `randomisations_in_domain` | `randomisation` | Randomisation records for this participant in this domain. |
| `days_since_previous_record` | `daily_icu` | Gap in days to the previous daily record; 1 is consecutive. |
| `death_date_or_infinity` | `daily_icu` | Date of death, or a date nothing can exceed when none is recorded. |
| `death_date_and_status_agree` | `outcome_30d` | Whether vital status and the presence of a death date are consistent. |
| `distinct_death_dates_for_participant` | `outcome_30d` | Distinct death dates recorded across domains. |
| `distinct_admission_dates_for_participant` | `outcome_30d` | Distinct ICU admission dates across domains. |
| `vital_status_consistent_at_shared_window` | `outcome_30d` | Whether domains sharing a window end date agree on vital status. |
| `screening_date_for_participant` | `randomisation` | Screening date for this participant. |
| `entry_not_before_event` | all forms | Whether the record was entered on or after the event it describes. |

Adding a context column is how the vocabulary grows. A new column must be
added to `R/validate/context.R`, documented in this table, and covered by a
test in `tests/testthat/test-validation-rules.R`.

