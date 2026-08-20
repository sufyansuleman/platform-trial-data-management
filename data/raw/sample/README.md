# Sample EDC exports

A four-line excerpt of six of the 125 files the simulation writes to
`data/raw/`. The rest are gitignored -- they are generated, not authored.

These six are the interesting ones. Each shows a local convention that the
ingest layer has to detect and normalise:

| File | What it demonstrates |
|---|---|
| `screening_DK-01.csv` | Baseline: `DD-MM-YYYY` dates, `.` decimal, kg, umol/L, UTF-8 |
| `screening_DK-03.csv` | **Latin-1 encoded.** `site_name` is unreadable as UTF-8 |
| `screening_DK-07.csv` | Weight exported in **pounds**, as the site declares |
| `screening_NL-01.csv` | **Decimal comma**, creatinine in **mg/dL** |
| `screening_SE-01.csv` | ISO `YYYY-MM-DD` dates |
| `daily_icu_DK-01.csv` | The daily record grain |

Regenerate the full set with `Rscript -e 'targets::tar_make()'`.
