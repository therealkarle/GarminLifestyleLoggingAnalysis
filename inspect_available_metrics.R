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

  csv_files <- source_files(materialized, "\\.csv$")
  csv_columns <- list()
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
  names_found <- sort(unique(c(names_found, names(csv_columns))), na.last = TRUE)
  list(names = names_found, samples = samples, json_files = length(json_files), csv_files = length(csv_files))
}

read_lifestyle_inventory <- function(materialized, start, end, excluded) {
  files <- if (!is.null(materialized$direct_json)) materialized$direct_json else source_files(materialized, "LifestyleLogging\\.json$")
  rows <- list()
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
      }
    }
  }
  rows
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
excluded <- norm(unlist(config$excluded_activities %||% list()))
activity_counts <- read_lifestyle_inventory(lifestyle_source, start, end, excluded)
output_path <- get_arg("--output") %||% file.path(dirname(config_path), "available_metrics_and_activities.txt")

configured_metrics <- config$sleep_metrics %||% list()
configured_metric_lines <- if (is.list(configured_metrics) && length(configured_metrics)) {
  vapply(names(configured_metrics), function(metric) {
    aliases <- as.character(unlist(configured_metrics[[metric]]))
    paste0("- ", metric, ": ", paste(aliases, collapse = ", "))
  }, character(1))
} else {
  character()
}

lines <- c(
  "Garmin LifestyleLogging analysis inventory",
  paste0("Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
  paste0("Date range: ", start, " to ", end),
  paste0("Config: ", config_path),
  "",
  "SLEEP METRICS / SOURCE FIELDS",
  paste0("JSON files scanned: ", sleep_inventory$json_files),
  paste0("CSV files scanned: ", sleep_inventory$csv_files),
  "Configured metric mappings:",
  if (length(configured_metric_lines)) configured_metric_lines else "- None; source fields below can be added to sleep_metrics.",
  "",
  "These scalar fields were found in the sleep source and can potentially be mapped under sleep_metrics.",
  ""
)
if (length(sleep_inventory$names)) {
  lines <- c(lines, vapply(sleep_inventory$names, function(name) {
    sample <- format_sample(sleep_inventory$samples[[name]])
    if (nzchar(sample)) paste0("- ", name, " (example: ", sample, ")") else paste0("- ", name)
  }, character(1)))
} else {
  lines <- c(lines, "- No scalar sleep fields found.")
}

lines <- c(lines, "", "ACTIVITIES / EXPLICIT CHOICES", "Missing activity entries are ignored. Counts are per activity-day after duplicate entries are merged.", "")
if (length(activity_counts)) {
  activity_names <- sort(names(activity_counts))
  lines <- c(lines, vapply(activity_names, function(activity) {
    counts <- activity_counts[[activity]]
    paste0("- ", activity, ": yes=", counts[["yes"]], ", explicit_no=", counts[["explicit_no"]])
  }, character(1)))
} else {
  lines <- c(lines, "- No explicit activity choices found.")
}

writeLines(lines, output_path, useBytes = TRUE)
progress("[Inventory] Wrote: ", normalizePath(output_path, mustWork = FALSE))
