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

## Download Garmin data

1. Sign in to your Garmin account and open the [Garmin Account Data Management page](https://www.garmin.com/account/datamanagement/).
2. Request an export of your account data and wait for Garmin's confirmation email. The export can take some time to become available.
3. Download the provided ZIP archive and extract it locally. Keep the extracted export outside version control.
4. Point `input_path` in `GarminLifestyleAnalysisConfig.yaml` to the extracted export directory, the ZIP file, or the direct `LifestyleLogging.json` file.

The analysis accepts all three input forms. Do not commit personal Garmin data,
the downloaded ZIP archive, or generated results to the repository; the local
config, Garmin exports, and output directory are already ignored by Git.

## Run

From the repository directory:

```sh
Rscript lifestyle_sleep_analysis.R --config GarminLifestyleAnalysisConfig.yaml
```

Alternatively, open `lifestyle_sleep_analysis.R` in RStudio and click
`Source`. In that case, make sure `GarminLifestyleAnalysisConfig.yaml` is in
the repository directory or adjust the configuration path in the script as
needed.

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
`interpretation` (`better`, `worse`, or `not_significant`). The classification
CSVs are direction-aware: `significant_positive` contains significant
improvements and `significant_negative` contains significant deteriorations.
For a metric where `lower` is better, a negative `delta` is therefore written
to the positive CSV.

`sleep_metrics` supports both alias lists and direct JSON field names in the
same mapping. Use an empty mapping for a field that should keep its JSON name,
for example `averageHR:` or `averageSPO2:`. A scalar alias such as
`averageHR: averageHR` is accepted as well.

Derived sleep metrics can be defined under `derived_sleep_metrics`. A formula
may reference scalar fields from the Garmin sleep JSON, configured metric names,
and earlier derived metrics. Supported operators are `+`, `-`, `*`, `/`, and
parentheses; formulas are evaluated as arithmetic expressions and are never
executed as R code. For example:

```yaml
derived_sleep_metrics:
  DeepSleep_Share:
    formula: "deepSleepSeconds / (Sleep_Duration * 3600)"
```

`Sleep_Duration` is normalized to hours, while `deepSleepSeconds` remains in
seconds. Therefore `deepSleepSeconds / Sleep_Duration` is a seconds-per-sleep-
hour metric; use the `* 3600` denominator when the desired result is a share.
For a compact definition, a formula can also be placed directly under
`sleep_metrics`, for example `DeepSleep_Share: { formula: "..." }`.
Missing operands and division by zero produce a missing value for that night.

Descriptive statistics are reported per activity/metric for `done` and
`not_done`. The CSV columns appear in this order directly after each group's
count: `*_n`, `*_mean`, `*_median`, `*_sd`, `*_interval_low`, and
`*_interval_high`. The native/assumed breakdown contains counts only:
`native_not_done_n` and `assumed_not_done_n`.

Garmin assigns a sleep night to its wake-up date, while LifestyleLogging uses
the bedtime/start date. The analysis therefore matches a lifestyle entry with
the sleep record from the following calendar date.
