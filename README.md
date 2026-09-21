# Garmin Lifestyle Logging Analysis

This repository contains the independent R analysis for comparing Garmin
LifestyleLogging activities with sleep metrics. It accepts an extracted Garmin
export directory, a ZIP export, or a direct `LifestyleLogging.json` file and
writes ranked CSV tables plus a JSON result file.

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

## Configuration

The example configuration documents the supported input formats and analysis
options. `output_dir: "Out"` keeps generated results in the repository's
`Out/` directory. Keep exported Garmin data and generated output outside
version control; `.gitignore` already excludes the local config, Garmin
exports, and output directory.

Metric directions are configured independently under `metric_directions`.
Use `higher` when a higher value is better and `lower` when a lower value is
better. The unchanged standard metrics are `Sleep_Score`, `Sleep_Duration`,
`HRV`, and `RHR`; their defaults are higher, higher, higher, and lower.
Optional metrics such as `Stress`, `Restless_Moments`, and `Awake_Time` use
lower by default when they are added to `sleep_metrics`. Custom metrics not
listed in the defaults use higher. Each result contains `better_is` and
`interpretation` (`better`, `worse`, or `not_significant`).

Garmin assigns a sleep night to its wake-up date, while LifestyleLogging uses
the bedtime/start date. The analysis therefore matches a lifestyle entry with
the sleep record from the following calendar date.
