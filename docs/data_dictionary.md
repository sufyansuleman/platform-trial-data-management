# Data dictionary

> **Generated file.** Produced by `scripts/generate_docs.R` from `config/`. Edit the configuration, not this file. Last generated 21 August 2026.

Every field in every form, with its type, whether it is required, and the
constraints the schema enforces. These are the **hard bounds**: a value
outside them is certainly wrong. The tighter *plausibility* bounds that
generate queries live in [validation_plan.md](validation_plan.md) and are
deliberately narrower — see rule RNG-001 for why.

## Conventions

- **No free text anywhere.** Every field is coded, dated or numeric. This
  keeps the dataset trivially safe to share and models good clinical data
  management practice: free text cannot be validated, cannot be analysed
  without manual coding, and is where identifiable information leaks into
  a trial database.
- **No dates of birth.** Age in whole years only.
- **Identifiers are trial-generated.** No national identifier, hospital
  number or any other externally meaningful key appears in the data.
- **Internal units are kilograms and micromoles per litre.** Sites may
  export in pounds or mg/dL; ingest converts and logs the conversion.
- **Dates are stored as ISO 8601** after ingest. Sites export in their own
  local format.

## `adverse_events`

**Grain.** Zero or more rows per participant.

**Key.** `ae_id`

| Field | Type | Required | Constraint | Description |
|---|---|---|---|---|
| `ae_id` | character | yes | matches `^AE-[0-9]{6}$` | Adverse event identifier. |
| `participant_id` | character | yes | matches `^P-[0-9]{6}$` | Participant. |
| `site_id` | character | yes | matches `^[A-Z]{2}-[0-9]{2}$` | Reporting site. |
| `ae_code` | code | yes | one of: `AE-BLEED`, `AE-THROMB`, `AE-INFECT`, `AE-ARRHY`, `AE-AKI`, `AE-HYPOT`, `AE-ALLERG`, `AE-PNEU`, `AE-DELIR`, `AE-HYPER` | Coded adverse event term. No free text by design. |
| `onset_date` | date | yes | — | Date of adverse event onset. |
| `serious` | code | yes | one of: `0`, `1` | Meets seriousness criteria. |
| `related` | code | yes | one of: `0`, `1`, `2` | Relatedness to trial intervention, 0 not related 1 possibly 2 probably. |
| `entry_date` | date | yes | — | Date the record was entered into the EDC. |
| `site_name` | character | no | — | Site label as exported by the site, denormalised. Subject to encoding damage. |

## `daily_icu`

**Grain.** One row per participant per ICU day, day 0 to day 90.

**Key.** `participant_id` + `icu_day`

| Field | Type | Required | Constraint | Description |
|---|---|---|---|---|
| `record_id` | character | yes | matches `^DLY-[0-9]{7}$` | Daily record identifier. |
| `participant_id` | character | yes | matches `^P-[0-9]{6}$` | Participant. |
| `site_id` | character | yes | matches `^[A-Z]{2}-[0-9]{2}$` | Site holding the participant on this day. |
| `icu_day` | integer | yes | 0 to 90 | Days since first randomisation. |
| `record_date` | date | yes | — | Calendar date the day refers to. |
| `alive` | code | yes | one of: `0`, `1` | Alive at any point during this day. |
| `in_icu` | code | yes | one of: `0`, `1` | Present in an ICU during this day. |
| `mechanical_ventilation` | code | yes | one of: `0`, `1` | Invasive mechanical ventilation received. |
| `vasopressors` | code | yes | one of: `0`, `1` | Vasopressor or inotropic support received. |
| `renal_replacement` | code | yes | one of: `0`, `1` | Renal replacement therapy received. |
| `icu_location` | character | no | matches `^[A-Z]{2}-[0-9]{2}-ICU[0-9]$` | ICU unit identifier, blank when not in ICU. |
| `heart_rate` | integer | no | 20 to 220 | Heart rate in beats per minute. |
| `temperature_c` | number | no | 30 to 43 | Core temperature in Celsius. |
| `entry_date` | date | yes | — | Date the record was entered into the EDC. |
| `site_name` | character | no | — | Site label as exported by the site, denormalised. Subject to encoding damage. |

## `outcome_30d`

**Grain.** One row per participant per domain.

**Key.** `participant_id` + `domain`

| Field | Type | Required | Constraint | Description |
|---|---|---|---|---|
| `participant_id` | character | yes | matches `^P-[0-9]{6}$` | Participant. |
| `domain` | code | yes | one of: `FLUID`, `ANTICOAG`, `BUFFER` | Domain this outcome belongs to. |
| `site_id` | character | yes | matches `^[A-Z]{2}-[0-9]{2}$` | Reporting site. |
| `vital_status_30d` | code | yes | one of: `alive`, `dead`, `unknown` | Vital status 30 days after randomisation in this domain. |
| `death_date` | date | no | — | Date of death, blank if alive at 30 days. |
| `icu_admission_date` | date | yes | — | First ICU admission date. |
| `hospital_discharge_date` | date | no | — | Hospital discharge date, blank if still admitted or died. |
| `entry_date` | date | yes | — | Date the record was entered into the EDC. |
| `site_name` | character | no | — | Site label as exported by the site, denormalised. Subject to encoding damage. |

## `randomisation`

**Grain.** One row per participant per domain entered.

**Key.** `randomisation_id`

| Field | Type | Required | Constraint | Description |
|---|---|---|---|---|
| `randomisation_id` | character | yes | matches `^RND-[0-9]{6}$` | Randomisation record identifier. |
| `participant_id` | character | yes | matches `^P-[0-9]{6}$` | Participant randomised. |
| `site_id` | character | yes | matches `^[A-Z]{2}-[0-9]{2}$` | Randomising site. |
| `domain` | code | yes | one of: `FLUID`, `ANTICOAG`, `BUFFER` | Platform domain. |
| `arm` | character | yes | — | Allocated arm within the domain. |
| `randomisation_datetime` | datetime | yes | — | Date and time of allocation. |
| `allocation_ratio` | character | yes | — | Allocation ratio in force at the time, written as a:b. |
| `entry_date` | date | yes | — | Date the record was entered into the EDC. |
| `site_name` | character | no | — | Site label as exported by the site, denormalised. Subject to encoding damage. |

## `screening`

**Grain.** One row per screened patient.

**Key.** `screening_id`

| Field | Type | Required | Constraint | Description |
|---|---|---|---|---|
| `screening_id` | character | yes | matches `^SCR-[0-9]{6}$` | Screening record identifier. |
| `participant_id` | character | no | matches `^P-[0-9]{6}$` | Assigned only if the patient was enrolled, blank otherwise. |
| `site_id` | character | yes | matches `^[A-Z]{2}-[0-9]{2}$` | Screening site. |
| `screening_date` | date | yes | — | Date of screening assessment. |
| `age_years` | integer | yes | 18 to 120 | Age at screening. |
| `sex` | code | yes | one of: `F`, `M` | Recorded sex. |
| `weight_kg` | number | yes | 30 to 250 | Body weight, normalised to kg at ingest. |
| `creatinine` | number | yes | 10 to 1200 | Serum creatinine, normalised to umol/L at ingest. |
| `severity_score` | integer | yes | 0 to 71 | Illness severity index at screening. |
| `elig_icu` | code | yes | one of: `0`, `1` | Meets ICU admission criterion. |
| `elig_consent` | code | yes | one of: `0`, `1` | Consent obtained. |
| `elig_no_exclusion` | code | yes | one of: `0`, `1` | Free of all exclusion criteria. |
| `enrolled` | code | yes | one of: `0`, `1` | Proceeded to randomisation. |
| `entry_date` | date | yes | — | Date the record was entered into the EDC. |
| `site_name` | character | no | — | Site label as exported by the site, denormalised. Subject to encoding damage. |

## Derived variables

Not captured on any form; computed by `R/derive/`.

| Variable | Definition |
|---|---|
| `days_alive_without_life_support` | Days in the 30 days after randomisation into that domain on which the participant was alive and free of invasive mechanical ventilation, vasopressor or inotropic support, and renal replacement therapy. Death within 30 days scores 0. See DEC-012 and DEC-013. |
| `unknown_days` | Days in the window whose status could not be determined, because no record exists and no discharge explains its absence, or because duplicate records disagree. |
| `complete` | Whether the endpoint rests entirely on observed days. |

