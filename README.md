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
2. Request an export of your account data and wait for Garmin's confirmation email. The export can take some time (usualy 48h acordign to Garmin) to become available.
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
  all_significant: true
  all_unsignificant: true
  per_metric_combined: true
  per_metric_classifications: true
  per_metric_significant: true
  per_metric_unsignificant: true
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

`all_combined` writes `all.csv`; `all_classifications` is the fallback switch
for all classification CSVs. `all_significant` controls both significant files
(`all_significant_positive.csv` and `all_significant_negative.csv`), while
`all_unsignificant` controls `all_not_significant.csv`. When explicitly set,
these two switches override `all_classifications`; set
`all_unsignificant: false` to write only the significant all-metric CSVs.
An enabled CSV export is created only when it contains at least one result;
the analysis never writes header-only CSV files.

`per_metric_combined` writes one `<metric>_all.csv` file per metric.
`per_metric_classifications` is the fallback for that metric's classification
CSVs; `per_metric_significant` and `per_metric_unsignificant` override it in
the same way. For a specific metric, add an optional mapping under
`analysis_output.per_metric_overrides`; its `classifications`, `significant`,
and `unsignificant` booleans take priority over the per-metric defaults:

```yaml
analysis_output:
  per_metric_unsignificant: false
  per_metric_overrides:
    Sleep_Score:
      # This metric is the exception: also write its not-significant CSV.
      unsignificant: true
```

Missing switches default to `true` for backward compatibility, and each
switch must be a single YAML boolean value. Set `json: false` to disable the
`lifestyle_sleep_analysis.json` result file.

### Direct activity comparison tests

`activity_comparison_tests` optionally defines direct, independent comparisons
between two groups of lifestyle entries. Each group's `label` is optional; when
omitted, its expression identifies the group in the results. The tests are written to the separate
`activity_comparison_tests.csv`; the existing activity-versus-not-done CSVs and
JSON file are unchanged. Every configured test is evaluated for every selected
sleep metric and uses the same Welch two-sample test, confidence interval,
significance level, and `metric_directions` interpretation as the main
analysis.

`analysis_output.activity_comparison_combined` controls the existing combined
file (default: `true`). Optional classification CSVs are controlled by
`activity_comparison_classifications`, which defaults to `false` for existing
configurations. `activity_comparison_significant` overrides that fallback and
writes one `activity_comparison_tests_significant.csv` containing both positive
and negative significant outcomes. `activity_comparison_unsignificant` writes
`activity_comparison_tests_not_significant.csv`. Per-test exceptions use the
configured comparison `name`:

```yaml
analysis_output:
  activity_comparison_significant: true
  activity_comparison_unsignificant: false
  activity_comparison_overrides:
    "Display off: 1h vs only 30min":
      unsignificant: true
```

```yaml
activity_comparison_tests:
  - name: "Display off: 1h vs only 30min"
    group_a:
      label: "1 hour before bed"
      expression: "`Display off 1h before bed` AND `Display off 30min before bed`"
    group_b:
      label: "only 30 minutes before bed"
      expression: "`Display off 30min before bed` AND NOT `Display off 1h before bed`"
```

Expressions accept backtick-quoted activity names, `NOT`, `AND`, `OR`, and
parentheses. Operator precedence is `NOT`, then `AND`, then `OR`. Invalid
syntax or a name that is not a configured or observed activity stops the run
with a configuration error. Missing logs follow `missing_activity_is_no` and
`missing_activity_is_no_by_activity`: when absence is not considered `no`, a
night whose rule cannot be evaluated is omitted from that group only. The
other group's result is evaluated independently. If a night matches both
groups, it is included in both; use mutually exclusive expressions if that is
not desired. `unknown_excluded_n` counts distinct metric-available nights for
which either group's rule is unknown.

The comparison CSV includes any supplied labels, source expressions for both
groups, their descriptive statistics, `unknown_excluded_n`, the
mean difference `mean(group_a) - mean(group_b)`, its confidence interval,
p-value, direction-aware classification, and metric direction. Like the other
results, these are observational associations, not evidence that the activity
caused the outcome.

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

## Data interpretation and statistical method

For each lifestyle activity and sleep metric, the analysis compares two groups:

- <code>done</code>: The activity was explicitly recorded as completed on that day.
- <code>not_done</code>: The activity was explicitly recorded as not completed.
  If <code>missing_activity_is_no: true</code> is set, days without an entry are
  also treated as assumed non-completion. These cases are reported separately
  as <code>assumed_not_done_n</code>.

The sleep night is identified by its wake-up date. Therefore, for example, the
lifestyle entry from January 20 is matched with the sleep night ending on
January 21. Nights without a usable metric value are excluded from the
respective statistical calculation.

### What do the reported statistics show?

For both groups, the analysis reports <code>n</code>, mean, median, and standard
deviation. By default, <code>interval_low</code> and <code>interval_high</code>
are the 80% quantile interval of the observed values
(<code>value_interval: 0.80</code>). This interval describes the spread of the
observed data; it is not a confidence interval for the group mean.

The central difference is always calculated as:

$$
\Delta = \operatorname{mean}(\text{done}) -
\operatorname{mean}(\text{not\_done})
$$

A positive <code>delta</code> therefore means that the metric is higher in the
<code>done</code> group. Whether this is better or worse depends on
<code>better_is</code>:

- With <code>better_is: higher</code>, a positive <code>delta</code> is an improvement.
- With <code>better_is: lower</code>, a negative <code>delta</code> is an improvement,
  for example for resting heart rate (<code>RHR</code>).

Consequently, <code>significant_positive</code> and
<code>significant_negative</code> describe the interpreted direction of the
result, not necessarily the mathematical sign of <code>delta</code>.

### What is the Welch two-sample t-test?

The Welch test assesses whether the means of two groups differ in a
statistically plausible way without assuming equal variances. This is useful
here because the number of observations and the variability can differ between
the <code>done</code> and <code>not_done</code> groups.

For the two groups, the following quantities are used:

$$
\begin{aligned}
n_1,\ \bar{x},\ s_1^2 &=
\text{count, mean, and variance of the done group} \\
n_2,\ \bar{y},\ s_2^2 &=
\text{count, mean, and variance of the not\_done group} \\
\Delta &= \bar{x} - \bar{y}
\end{aligned}
$$

The standard error of the difference in means is:

$$
SE(\Delta) =
\sqrt{\frac{s_1^2}{n_1} + \frac{s_2^2}{n_2}}
$$

The test statistic is:

$$
t = \frac{\bar{x} - \bar{y}}{SE(\Delta)}
$$

Because equal variances are not assumed, the test uses the
Welch-Satterthwaite approximation for the degrees of freedom:

$$
\nu =
\frac{\left(\frac{s_1^2}{n_1} + \frac{s_2^2}{n_2}\right)^2}
{\frac{\left(\frac{s_1^2}{n_1}\right)^2}{n_1 - 1}
 + \frac{\left(\frac{s_2^2}{n_2}\right)^2}{n_2 - 1}}
$$

The two-sided p-value is obtained from the t-distribution with
<code>ν</code> degrees of freedom:

$$
p = 2\left(1 - F_{t,\nu}(|t|)\right)
$$

The implementation uses R's standard Welch-test implementation:

~~~r
stats::t.test(done_values, not_done_values,
              var.equal = FALSE,
              conf.level = confidence)
~~~

The test is only run when both groups contain at least two usable observations.
With <code>significance_level: 0.05</code>, a result is classified as
significant when <code>p_value &lt; 0.05</code>. The p-value does not indicate
how large or practically relevant the difference is. That requires considering
<code>delta</code>, the group means, and the sample sizes as well.

The confidence interval for the difference in means uses the same standard
error and degrees-of-freedom estimate:

$$
\Delta \pm t_{1-\alpha/2,\nu}\,SE(\Delta)
$$

With the default <code>confidence_interval: 0.95</code>, this is a 95%
confidence interval for <code>mean(done) - mean(not_done)</code>. If the
interval is entirely above zero, the difference is positive; if it is entirely
below zero, the difference is negative. The interval and p-value returned by
the Welch test are written as <code>delta_ci_low</code> and
<code>delta_ci_high</code>.

### How should a result be interpreted?

<code>interpretation: better</code> means that the difference is statistically
significant at the configured significance level and points in the direction
configured as better. <code>worse</code> indicates a significant deterioration.
<code>not_significant</code> means that the test did not provide sufficient
evidence for a difference at that significance level; it does not prove that
the groups are identical.

This is an observational analysis. A significant association does not
automatically mean that the lifestyle activity caused the change in the sleep
metric. Training load, illness, bedtime, day of the week, and the decision about
which days to record an activity can all influence the result. The many
activity/metric combinations are also not currently adjusted for multiple
testing. Results should therefore be assessed together with sample size, effect
size, confidence interval, and subject-matter plausibility rather than by
looking at the p-value alone.

The Welch test treats the individual nights as independent observations for the
calculation. For consecutive nights, this assumption may only be approximate;
the results should therefore be read as evidence of an association, not as
causal or definitive proof.
