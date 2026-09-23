#!/usr/bin/env Rscript

# Write an inventory of available sleep metrics and explicit LifestyleLogging
# activity choices. Missing activity entries are deliberately not counted.

if (!requireNamespace("yaml", quietly = TRUE) || !requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Install the R packages yaml and jsonlite.")
}

script_directory <- function() {
  files <- vapply(sys.frames(), function(frame) if (!is.null(frame$ofile)) frame$ofile else "", character(1))
  files <- files[nzchar(files)]
  if (length(files)) dirname(normalizePath(tail(files, 1))) else getwd()
}

analysis_script <- file.path(script_directory(), "lifestyle_sleep_analysis.R")
if (!file.exists(analysis_script)) stop("Cannot find lifestyle_sleep_analysis.R next to this script.")
source(analysis_script, local = TRUE)

progress <- function(...) {
  cat(..., "\n", sep = "")
  flush.console()
}

scalar_names <- function(value, names_seen = character()) {
  if (!is.list(value)) return(names_seen)
  for (name in names(value)) {
    child <- value[[name]]
    if (is.list(child)) {
      names_seen <- scalar_names(child, names_seen)
    } else if (length(child) && nzchar(name)) {
      names_seen <- c(names_seen, name)
    }
  }
  unique(names_seen)
}

scalar_samples <- function(value, samples = list()) {
  if (!is.list(value)) return(samples)
  for (name in names(value)) {
    child <- value[[name]]
    if (is.list(child)) {
      samples <- scalar_samples(child, samples)
    } else if (length(child) && nzchar(name) && is.null(samples[[name]])) {
      samples[[name]] <- trimws(as.character(child[[1]]))
    }
  }
  samples
}

scalar_presence <- function(value, fields = list()) {
  if (!is.list(value)) return(fields)
  for (name in names(value)) {
    child <- value[[name]]
    if (is.list(child)) {
      fields <- scalar_presence(child, fields)
    } else if (length(child) && nzchar(name)) {
      text <- trimws(as.character(child[[1]]))
      if (!is.na(text) && nzchar(text) && !identical(text, "NA")) fields[[name]] <- TRUE
    }
  }
  fields
}

sleep_metric_records <- function(materialized) {
  records <- list()
  add_record <- function(day, fields) {
    if (is.na(day) || !length(fields)) return()
    key <- as.character(day)
    if (is.null(records[[key]])) records[[key]] <<- list()
    records[[key]] <<- c(records[[key]], fields)
  }

  for (path in source_files(materialized, "_sleepData\\.json$")) {
    payload <- tryCatch(read_json(path), error = function(e) NULL)
    if (!is.list(payload)) next
    entries <- if (!is.null(payload$calendarDate) || !is.null(payload$date)) list(payload) else payload
    for (entry in entries) {
      if (!is.list(entry)) next
      day <- parse_date(entry$calendarDate %||% entry$date)
      add_record(day, scalar_presence(entry))
    }
  }

  # JSON is the authoritative source. Inspect CSV sleep files only for older
  # exports that contain no _sleepData.json files at all.
  if (!length(source_files(materialized, "_sleepData\\.json$"))) {
    for (path in source_files(materialized, "\\.csv$")) {
      if (!grepl("sleep|schlaf", basename(path), ignore.case = TRUE)) next
      data <- read_csv_flexible(path)
      if (is.null(data) || !nrow(data)) next
      date_candidates <- names(data)[norm(names(data)) %in% c("date", "datum", "sleep date", "calendar date")]
      if (!length(date_candidates)) next
      date_column <- date_candidates[[1]]
      for (i in seq_len(nrow(data))) {
        fields <- list()
        for (name in names(data)) {
          value <- data[[name]][[i]]
          if (!is.na(value) && nzchar(trimws(as.character(value)))) fields[[name]] <- TRUE
        }
        add_record(parse_date(data[[date_column]][[i]]), fields)
      }
    }
  }
  records
}

read_sleep_inventory <- function(materialized) {
  names_found <- character()
  samples <- list()
  json_files <- source_files(materialized, "_sleepData\\.json$")
  for (path in json_files) {
    payload <- tryCatch(read_json(path), error = function(e) NULL)
    if (is.list(payload)) {
      names_found <- scalar_names(payload, names_found)
      samples <- scalar_samples(payload, samples)
    }
  }

  csv_files <- character()
  csv_columns <- list()
  if (!length(json_files)) {
    csv_files <- source_files(materialized, "\\.csv$")
    for (path in csv_files) {
      data <- read_csv_flexible(path)
      if (!is.null(data) && ncol(data)) {
        for (name in names(data)) {
          csv_columns[[name]] <- TRUE
          if (is.null(samples[[name]])) {
            values <- data[[name]][!is.na(data[[name]]) & nzchar(trimws(as.character(data[[name]])))]
            if (length(values)) samples[[name]] <- trimws(as.character(values[[1]]))
          }
        }
      }
    }
  }
  names_found <- sort(unique(c(names_found, names(csv_columns))), na.last = TRUE)
  list(names = names_found, samples = samples, json_files = length(json_files), csv_files = length(csv_files))
}

read_lifestyle_inventory <- function(materialized, sleep_records, configured_metrics, start, end, excluded) {
  files <- if (!is.null(materialized$direct_json)) materialized$direct_json else source_files(materialized, "LifestyleLogging\\.json$")
  rows <- list()
  discovered_metrics <- unique(c(configured_metrics, unlist(lapply(sleep_records, names), use.names = FALSE)))
  discovered_metrics <- sort(discovered_metrics[!is.na(discovered_metrics) & nzchar(discovered_metrics)])
  metric_counts <- setNames(lapply(discovered_metrics, function(x) c(n_done = 0L, n_not_done = 0L)), discovered_metrics)
  for (path in files) {
    payload <- tryCatch(read_json(path), error = function(e) NULL)
    parsed <- lifestyle_rows(payload)
    for (day_key in names(parsed)) {
      day <- parse_date(day_key)
      if (is.na(day) || day < start || day > end) next
      for (activity in names(parsed[[day_key]])) {
        if (norm(activity) %in% excluded) next
        status <- parsed[[day_key]][[activity]]
        if (is.null(rows[[activity]])) rows[[activity]] <- c(yes = 0L, explicit_no = 0L)
        if (isTRUE(status)) rows[[activity]][["yes"]] <- rows[[activity]][["yes"]] + 1L
        else if (identical(status, FALSE)) rows[[activity]][["explicit_no"]] <- rows[[activity]][["explicit_no"]] + 1L

        sleep_values <- sleep_records[[sleep_key_for_lifestyle_day(day)]]
        if (is.null(sleep_values)) next
        for (metric in names(sleep_values)) {
          if (isTRUE(status)) metric_counts[[metric]][["n_done"]] <- metric_counts[[metric]][["n_done"]] + 1L
          else if (identical(status, FALSE)) metric_counts[[metric]][["n_not_done"]] <- metric_counts[[metric]][["n_not_done"]] + 1L
        }
      }
    }
  }
  list(activity_counts = rows, metric_counts = metric_counts)
}

format_sample <- function(value) {
  value <- as.character(value %||% "")
  if (!nzchar(value)) "" else substr(gsub("[[:space:]]+", " ", value), 1, 80)
}

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name) { i <- match(name, args); if (is.na(i) || i == length(args)) NULL else args[[i + 1]] }
config_path <- get_arg("--config") %||% get_arg("-c") %||% find_config()
config_path <- normalizePath(config_path, mustWork = TRUE)
config <- yaml::read_yaml(config_path)
input_path <- config$input_path
if (is.null(input_path) || !nzchar(input_path)) stop("Set input_path in the config.")
sleep_input <- config$sleep_input %||% ""
if (!nzchar(sleep_input)) sleep_input <- input_path
start <- parse_date(config$start_date); end <- parse_date(config$end_date)
if (is.na(start) || is.na(end) || end < start) stop("Config requires valid start_date and end_date.")

lifestyle_source <- materialize_source(input_path)
sleep_source <- materialize_source(sleep_input)
on.exit({
  if (lifestyle_source$cleanup) unlink(lifestyle_source$root, recursive = TRUE)
  if (sleep_source$cleanup && !identical(sleep_source$root, lifestyle_source$root)) unlink(sleep_source$root, recursive = TRUE)
}, add = TRUE)

sleep_inventory <- read_sleep_inventory(sleep_source)
specs <- metric_specs(config)
# Keep the inventory aligned with the analysis: configured HRV and RHR are
# available from Garmin's daily Health Status and UDS exports as well.
sleep_records <- merge_metric_rows(
  sleep_metric_records(sleep_source),
  daily_health_metric_rows(sleep_source, specs)
)
excluded <- norm(unlist(config$excluded_activities %||% list()))
inventory <- read_lifestyle_inventory(lifestyle_source, sleep_records, names(specs), start, end, excluded)
activity_counts <- inventory$activity_counts
metric_counts <- inventory$metric_counts

configured_output_dir <- config$output_dir %||% "Out"
base_output_dir <- resolve_output_dir(config_path, configured_output_dir)
inventory_root <- file.path(base_output_dir, "available_metrics_and_activities")
dir.create(inventory_root, recursive = TRUE, showWarnings = FALSE)
run_index <- 1L
while (dir.exists(file.path(inventory_root, paste0(format(Sys.Date(), "%Y-%m-%d"), "_Inventory_", run_index)))) run_index <- run_index + 1L
output_dir <- file.path(inventory_root, paste0(format(Sys.Date(), "%Y-%m-%d"), "_Inventory_", run_index))
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

inventory_config <- config$inventory_output %||% list()
write_txt <- if (is.null(inventory_config$txt)) TRUE else isTRUE(inventory_config$txt)
write_csv <- if (is.null(inventory_config$csv)) TRUE else isTRUE(inventory_config$csv)

configured_metrics <- config$sleep_metrics %||% list()
configured_metric_lines <- if (is.list(configured_metrics) && length(configured_metrics)) {
  vapply(names(configured_metrics), function(metric) {
    aliases <- as.character(unlist(configured_metrics[[metric]]))
    if (!length(aliases) || !any(nzchar(aliases))) aliases <- metric
    paste0("- ", metric, ": ", paste(aliases, collapse = ", "))
  }, character(1))
} else {
  character()
}

metric_lines <- character()
if (length(metric_counts)) {
  metric_lines <- names(metric_counts)
} else {
  metric_lines <- "No sleep metrics found."
}

activity_lines <- c(
  "Garmin LifestyleLogging activities",
  paste0("Date range: ", start, " to ", end),
  "Missing activity entries are ignored.",
  "",
  "activity, n_done, n_not_done, n_total"
)
if (length(activity_counts)) {
  activity_lines <- c(activity_lines, vapply(sort(names(activity_counts)), function(activity) {
    counts <- activity_counts[[activity]]
    paste0(activity, ", ", counts[["yes"]], ", ", counts[["explicit_no"]], ", ", counts[["yes"]] + counts[["explicit_no"]])
  }, character(1)))
} else {
  activity_lines <- c(activity_lines, "No explicit activity choices found.")
}

if (write_txt) {
  writeLines(metric_lines, file.path(output_dir, "sleep_metrics.txt"), useBytes = TRUE)
  writeLines(activity_lines, file.path(output_dir, "activities.txt"), useBytes = TRUE)
}

if (write_csv) {
  activity_frame <- if (length(activity_counts)) {
    do.call(rbind, lapply(sort(names(activity_counts)), function(activity) {
      n_done <- activity_counts[[activity]][["yes"]]
      n_not_done <- activity_counts[[activity]][["explicit_no"]]
      data.frame(activity = activity, n_done = n_done, n_not_done = n_not_done, n_total = n_done + n_not_done, stringsAsFactors = FALSE)
    }))
  } else data.frame(activity = character(), n_done = integer(), n_not_done = integer(), n_total = integer())
  utils::write.csv(activity_frame, file.path(output_dir, "activities.csv"), row.names = FALSE, na = "")
}

progress("[Inventory] Output directory: ", normalizePath(output_dir, mustWork = FALSE))
