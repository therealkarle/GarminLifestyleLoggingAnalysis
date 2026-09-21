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
exclusions, metrics, and output directory. The personal config is ignored by
Git.

## Run

From the repository directory:

```sh
Rscript lifestyle_sleep_analysis.R --config GarminLifestyleAnalysisConfig.yaml
```

The script creates a new run directory below the configured output directory.
It writes the ranked CSV files and `lifestyle_sleep_analysis.json` there.

## Configuration

The example configuration documents the supported input formats and analysis
options. Keep exported Garmin data and generated output outside version
control; `.gitignore` already excludes the local config and output directory.
