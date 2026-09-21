# Garmin Lifestyle Logging Analysis

This repository contains the independent R analysis for comparing Garmin
LifestyleLogging activities with sleep metrics. It accepts an extracted Garmin
export directory, a ZIP export, or a direct `LifestyleLogging.json` file and
writes configurable ranked CSV tables and optionally a JSON result file.

## Setup

Install the required R packages once:

```sh
Rscript -e "install.packages(c('yaml', 'jsonlite'))"
```

Copy `GarminLifestyleAnalysisConfig.yaml.example` to
`GarminLifestyleAnalysisConfig.yaml` and configure the input path, dates,
exclusions, metrics, and output directory. Relative paths are resolved from
the repository directory. The personal config is ignored by Git.

## Run

From the repository directory:

```sh
Rscript lifestyle_sleep_analysis.R --config GarminLifestyleAnalysisConfig.yaml
```

The script creates a new run directory below the configured output directory,
for example `Out/2026-09-21_Analysis_1/`. It writes the combined and
per-metric ranked CSV files and `lifestyle_sleep_analysis.json` there. Each
run is kept in its own directory so earlier results are not overwritten.

To inventory all scalar sleep fields found in the export and count explicit
activity choices, run:

```sh
Rscript inspect_available_metrics.R --config GarminLifestyleAnalysisConfig.yaml
```

This creates a separate dated folder below
`Out/available_metrics_and_activities/`. It contains `sleep_metrics.txt` and
`activities.txt` plus `activities.csv` when CSV output is enabled. Set
`inventory_output: { txt: false }` or `inventory_output: { csv: false }` in
the config to disable either format. The activity counts include only explicitly selected
`yes` and explicitly selected `no` values; missing activity entries are
ignored, regardless of `missing_activity_is_no`. Sleep metrics are discovered
primarily from all scalar fields in Garmin `_sleepData.json` records, including
fields that are not yet listed in `sleep_metrics`. Sleep-named CSV files are
used only as a fallback for older exports without `_sleepData.json`. Metrics
are written only as one metric name per line in `sleep_metrics.txt`. Activity
reports contain `n_done`, `n_not_done`, and `n_total`.

## Configuration

The example configuration documents the supported input formats and analysis
options. `output_dir: "Out"` keeps generated results in the repository's
`Out/` directory. Keep exported Garmin data and generated output outside
version control; `.gitignore` already excludes the local config, Garmin
exports, and output directory.

The analysis CSV groups can be enabled or disabled independently under
`analysis_output`. Missing switches default to `true` for compatibility with
older configurations:

```yaml
analysis_output:
  all_combined: true
  all_classifications: true
  per_metric_combined: true
  per_metric_classifications: true
  json: true
```

Performance timing is printed for materialization, lifestyle parsing, sleep
parsing, statistical analysis, and output generation. The optimized parsing
and lookup path is enabled by default. An optional configuration block is
available for larger exports:

```yaml
performance:
  enabled: true
  workers: 1
  backend: serial
```

`workers` and `backend: parallel` are accepted for forward-compatible
benchmarking, but execution remains deterministic and serial until a real
export demonstrates a reliable benefit from parallel workers. Parallel file
writing is never used.

`all_combined` writes `all.csv`; `all_classifications` writes the three
classification CSVs for all metrics. `per_metric_combined` writes one
`<metric>_all.csv` file per metric, while `per_metric_classifications` writes
the three classification CSVs per metric. Set `json: false` to disable the
`lifestyle_sleep_analysis.json` result file. Missing switches default to
`true`, and each switch must be a single YAML boolean value.

Metric directions are configured independently under `metric_directions`.
Use `higher` when a higher value is better and `lower` when a lower value is
better. The unchanged standard metrics are `Sleep_Score`, `Sleep_Duration`,
`HRV`, and `RHR`; their defaults are higher, higher, higher, and lower.
Optional metrics such as `Stress`, `Restless_Moments`, and `Awake_Time` use
lower by default when they are added to `sleep_metrics`. Custom metrics not
listed in the defaults use higher. Each result contains `better_is` and
`interpretation` (`better`, `worse`, or `not_significant`).

`sleep_metrics` supports both alias lists and direct JSON field names in the
same mapping. Use an empty mapping for a field that should keep its JSON name,
for example `averageHR:` or `averageSPO2:`. A scalar alias such as
`averageHR: averageHR` is accepted as well.

Descriptive statistics are reported once per activity/metric for the complete
sample (`not_mean`, `not_median`, `not_sd`, `not_interval_low`, and
`not_interval_high`). The group-specific fields contain counts only:
`done_n`, `native_not_done_n`, `assumed_not_done_n`, and `not_done_n`.

Garmin assigns a sleep night to its wake-up date, while LifestyleLogging uses
the bedtime/start date. The analysis therefore matches a lifestyle entry with
the sleep record from the following calendar date.
