#!/usr/bin/env Rscript

# Analyse Garmin LifestyleLogging against Garmin sleep metrics.

if (!requireNamespace("yaml", quietly = TRUE) || !requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Install the R packages yaml and jsonlite.")
}

DEFAULT_METRICS <- list(
  Sleep_Score = c("Score", "Sleep Score", "sleepScore", "overallSleepScore"),
  Sleep_Duration = c("Dauer", "Sleep Duration", "sleepDuration", "totalSleepTime"),
  HRV = c("HFV-Status", "HRV", "avgOvernightHrv", "averageOvernightHrv"),
  RHR = c("Ruheherzfrequenz", "Resting Heart Rate", "restingHeartRate", "restingHr")
)
# Direction used to interpret a higher or lower metric value. Custom metrics
# default to "higher" unless they are explicitly configured otherwise.
DEFAULT_METRIC_DIRECTIONS <- c(
  Sleep_Score = "higher",
  Sleep_Duration = "higher",
  HRV = "higher",
  RHR = "lower",
  Stress = "lower",
  Restless_Moments = "lower",
  Awake_Time = "lower"
)
TRUE_VALUES <- c("true", "yes", "y", "1", "done", "completed", "complete", "ja", "gemacht")
FALSE_VALUES <- c("false", "no", "n", "0", "not done", "not_done", "nicht gemacht", "nein")
`%||%` <- function(x, y) if (is.null(x)) y else x
progress <- function(...) {
  cat(..., "\n", sep = "")
  flush.console()
}

timed <- function(stage, expression) {
  started <- proc.time()[["elapsed"]]
  value <- force(expression)
  elapsed <- proc.time()[["elapsed"]] - started
  progress(sprintf("[Lifestyle] Timing %-24s %.3f s", paste0(stage, ":"), elapsed))
  value
}

# Garmin assigns a sleep night to the day it ends (the wake-up day), while
# LifestyleLogging assigns an entry to the day it starts (the bedtime day).
# Keep this boundary explicit so both sources refer to the same night.
sleep_key_for_lifestyle_day <- function(day) {
  format(as.Date(day, origin = "1970-01-01") + 1, "%Y-%m-%d")
}

norm <- function(x) {
  x <- tolower(trimws(ifelse(is.na(x), "", as.character(x))))
  gsub(" +", " ", gsub("_", " ", x))
}

# Parse the deliberately small boolean language used by activity comparison
# tests. Activity names must be quoted with backticks so expressions never
# execute arbitrary R code.
activity_expression_tokens <- function(expression) {
  expression <- trimws(as.character(expression %||% "")[1])
  if (!nzchar(expression)) stop("Activity comparison expressions must not be empty.")
  tokens <- list(); position <- 1L; expression_length <- nchar(expression)
  add_token <- function(type, value = NULL) tokens[[length(tokens) + 1L]] <<- list(type = type, value = value)
  while (position <= expression_length) {
    character_at_position <- substr(expression, position, position)
    if (grepl("\\s", character_at_position)) {
      position <- position + 1L
    } else if (character_at_position == "`") {
      closing <- regexpr("`", substr(expression, position + 1L, expression_length), fixed = TRUE)[1]
      if (closing < 0L) stop("Unterminated backtick-quoted activity name in comparison expression: ", expression)
      name <- substr(expression, position + 1L, position + closing - 1L)
      if (!nzchar(trimws(name))) stop("Activity names in comparison expressions must not be empty.")
      add_token("activity", name); position <- position + closing + 1L
    } else if (character_at_position %in% c("(", ")")) {
      add_token(character_at_position); position <- position + 1L
    } else {
      remaining <- substr(expression, position, expression_length)
      word <- regmatches(remaining, regexpr("^[A-Za-z]+", remaining, perl = TRUE))
      if (!length(word) || !nzchar(word) || !toupper(word) %in% c("AND", "OR", "NOT")) {
        stop("Expected a backtick-quoted activity name, AND, OR, NOT, or parentheses in comparison expression: ", expression)
      }
      add_token(tolower(word)); position <- position + nchar(word)
    }
  }
  tokens
}

parse_activity_expression <- function(expression, known_activities) {
  tokens <- activity_expression_tokens(expression); position <- 1L
  known_names <- setNames(as.character(known_activities), norm(known_activities))
  take <- function(type = NULL) {
    if (position > length(tokens)) return(NULL)
    token <- tokens[[position]]
    if (!is.null(type) && token$type != type) return(NULL)
    position <<- position + 1L
    token
  }
  parse_primary <- NULL; parse_not <- NULL; parse_and <- NULL; parse_or <- NULL
  parse_primary <- function() {
    token <- take("activity")
    if (!is.null(token)) {
      normalized_name <- norm(token$value)
      if (!normalized_name %in% names(known_names)) stop("Unknown activity in comparison expression: ", token$value)
      return(list(type = "activity", name = unname(known_names[[normalized_name]])))
    }
    if (!is.null(take("("))) {
      node <- parse_or()
      if (is.null(take(")"))) stop("Missing closing parenthesis in comparison expression: ", expression)
      return(node)
    }
    stop("Expected an activity name or opening parenthesis in comparison expression: ", expression)
  }
  parse_not <- function() {
    if (!is.null(take("not"))) return(list(type = "not", child = parse_not()))
    parse_primary()
  }
  parse_and <- function() {
    node <- parse_not()
    while (!is.null(take("and"))) node <- list(type = "and", left = node, right = parse_not())
    node
  }
  parse_or <- function() {
    node <- parse_and()
    while (!is.null(take("or"))) node <- list(type = "or", left = node, right = parse_and())
    node
  }
  tree <- parse_or()
  if (position <= length(tokens)) stop("Unexpected token in comparison expression: ", expression)
  tree
}

evaluate_activity_expression <- function(tree, statuses) {
  if (tree$type == "activity") return(statuses[[norm(tree$name)]])
  if (tree$type == "not") {
    value <- evaluate_activity_expression(tree$child, statuses)
    return(if (is.na(value)) NA else !value)
  }
  left <- evaluate_activity_expression(tree$left, statuses); right <- evaluate_activity_expression(tree$right, statuses)
  if (tree$type == "and") {
    if (identical(left, FALSE) || identical(right, FALSE)) return(FALSE)
    if (identical(left, TRUE) && identical(right, TRUE)) return(TRUE)
    return(NA)
  }
  if (tree$type == "or") {
    if (identical(left, TRUE) || identical(right, TRUE)) return(TRUE)
    if (identical(left, FALSE) && identical(right, FALSE)) return(FALSE)
    return(NA)
  }
  stop("Unsupported activity comparison expression node.")
}

comparison_tests <- function(config, known_activities) {
  configured <- config$activity_comparison_tests %||% list()
  if (!length(configured)) return(list())
  if (!is.list(configured)) stop("activity_comparison_tests must be a YAML list.")
  tests <- lapply(configured, function(test) {
    if (!is.list(test)) stop("Each activity_comparison_tests entry must be a mapping.")
    name <- trimws(as.character(test$name %||% "")[1])
    if (!nzchar(name)) stop("Each activity comparison test requires a name.")
    make_group <- function(group, key) {
      if (!is.list(group)) stop("Activity comparison test '", name, "' requires ", key, ".")
      label <- trimws(as.character(group$label %||% "")[1])
      expression <- trimws(as.character(group$expression %||% "")[1])
      if (!nzchar(expression)) stop("Activity comparison test '", name, "' requires an expression for ", key, ".")
      list(label = label, expression = expression, tree = parse_activity_expression(expression, known_activities))
    }
    list(name = name, group_a = make_group(test$group_a, "group_a"), group_b = make_group(test$group_b, "group_b"))
  })
  names <- vapply(tests, `[[`, character(1), "name")
  if (anyDuplicated(names)) stop("Activity comparison test names must be unique.")
  tests
}

activity_statuses_for_day <- function(day_entries, activities, config) {
  overrides <- config$missing_activity_is_no_by_activity %||% list()
  missing_default <- isTRUE(config$missing_activity_is_no %||% TRUE)
  entry_names <- names(day_entries %||% list())
  setNames(vapply(activities, function(activity) {
    found <- match(norm(activity), norm(entry_names), nomatch = 0L)
    if (found) return(isTRUE(day_entries[[found]]))
    override_name <- names(overrides)[norm(names(overrides)) == norm(activity)][1]
    missing_no <- if (length(override_name) && !is.na(override_name)) isTRUE(overrides[[override_name]]) else missing_default
    if (missing_no) FALSE else NA
  }, logical(1)), norm(activities))
}

parse_date <- function(x) {
  if (is.list(x) && length(x) >= 3) return(as.Date(sprintf("%04d-%02d-%02d", as.integer(x[[1]]), as.integer(x[[2]]), as.integer(x[[3]]))))
  if (length(x) == 0 || is.null(x) || is.na(x)[1]) return(as.Date(NA))
  text <- substr(as.character(x)[1], 1, 10)
  for (format in c("%Y-%m-%d", "%d.%m.%Y", "%m/%d/%Y")) {
    parsed <- as.Date(text, format = format)
    if (!is.na(parsed)) return(parsed)
  }
  as.Date(NA)
}

parse_number <- function(x) {
  if (length(x) == 0 || is.null(x) || is.na(x)[1]) return(NA_real_)
  text <- trimws(as.character(x)[1])
  if (!nzchar(text) || text %in% c("--", "-", "n/a", "NA")) return(NA_real_)
  text <- gsub("[^0-9,.-]", "", text)
  if (!nzchar(text)) return(NA_real_)
  if (grepl(",", text, fixed = TRUE) && grepl("\\.", text)) text <- sub(",", ".", gsub("\\.", "", text), fixed = TRUE) else text <- sub(",", ".", text, fixed = TRUE)
  suppressWarnings(as.numeric(text))
}

duration_to_hours <- function(x) {
  number <- parse_number(x); text <- as.character(ifelse(length(x) == 0 || is.null(x), "", x))[1]
  if (!is.na(number) && !grepl("[hHmMs]", text)) return(number)
  parts <- regmatches(text, regexec("(?:(\\d+)\\s*h)?\\s*(?:(\\d+)\\s*min?)?", text, perl = TRUE))[[1]]
  if (length(parts) >= 3 && (nzchar(parts[2]) || nzchar(parts[3]))) return((as.numeric(ifelse(nzchar(parts[2]), parts[2], 0)) * 60 + as.numeric(ifelse(nzchar(parts[3]), parts[3], 0))) / 60)
  NA_real_
}

read_json <- function(path) jsonlite::fromJSON(path, simplifyVector = FALSE)

# Flatten scalar JSON fields once per sleep record. The previous implementation
# recursively searched the complete record once for every configured metric.
json_scalar_values <- function(value, result = list()) {
  if (!is.list(value)) return(result)
  for (name in names(value)) {
    child <- value[[name]]
    if (is.list(child)) {
      result <- json_scalar_values(child, result)
    } else if (is.null(result[[name]])) {
      result[[name]] <- child
    }
  }
  result
}

json_scalar_value <- function(values, aliases) {
  if (!length(values) || !length(aliases)) return(NULL)
  names_values <- names(values)
  for (alias in as.character(aliases)) {
    exact <- match(alias, names_values, nomatch = 0L)
    if (exact) return(values[[exact]])
  }
  normalized <- norm(names_values)
  for (alias in as.character(aliases)) {
    match_index <- match(norm(alias), normalized, nomatch = 0L)
    if (match_index) return(values[[match_index]])
  }
  NULL
}

formula_tokens <- function(formula) {
  expression <- trimws(as.character(formula)[1])
  if (!nzchar(expression)) stop("Derived metric formulas must not be empty.")
  tokens <- character()
  position <- 1L
  expression_length <- nchar(expression)
  while (position <= expression_length) {
    character_at_position <- substr(expression, position, position)
    if (grepl("\\s", character_at_position)) {
      position <- position + 1L
      next
    }
    remaining <- substr(expression, position, expression_length)
    if (grepl("^[A-Za-z_]", remaining)) {
      match <- regmatches(remaining, regexpr("^[A-Za-z_][A-Za-z0-9_.]*", remaining, perl = TRUE))
      tokens <- c(tokens, match)
      position <- position + nchar(match)
      next
    }
    if (grepl("^[0-9.]", remaining)) {
      match <- regmatches(remaining, regexpr("^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?", remaining, perl = TRUE))
      if (!length(match) || !nzchar(match)) stop(sprintf("Invalid number near '%s'.", remaining))
      tokens <- c(tokens, match)
      position <- position + nchar(match)
      next
    }
    if (character_at_position %in% c("+", "-", "*", "/", "(", ")")) {
      tokens <- c(tokens, character_at_position)
      position <- position + 1L
      next
    }
    stop(sprintf("Unsupported character '%s' in derived metric formula.", character_at_position))
  }
  tokens
}

evaluate_derived_formula <- function(formula, values) {
  tokens <- formula_tokens(formula)
  token_index <- 1L
  peek <- function() if (token_index <= length(tokens)) tokens[[token_index]] else NULL
  consume <- function() {
    token <- peek()
    token_index <<- token_index + 1L
    token
  }
  finite_value <- function(value) {
    value <- suppressWarnings(as.numeric(value)[1])
    if (!length(value) || is.na(value) || !is.finite(value)) NA_real_ else value
  }
  parse_expression <- NULL
  parse_primary <- function() {
    token <- peek()
    if (is.null(token)) stop("Unexpected end of derived metric formula.")
    if (identical(token, "(")) {
      consume()
      value <- parse_expression()
      if (!identical(consume(), ")")) stop("Missing ')' in derived metric formula.")
      return(value)
    }
    if (grepl("^[A-Za-z_]", token)) {
      consume()
      return(finite_value(values[[token]]))
    }
    if (grepl("^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", token, perl = TRUE)) {
      consume()
      return(finite_value(token))
    }
    stop(sprintf("Unexpected token '%s' in derived metric formula.", token))
  }
  parse_unary <- function() {
    token <- peek()
    if (identical(token, "+")) {
      consume()
      return(parse_unary())
    }
    if (identical(token, "-")) {
      consume()
      value <- parse_unary()
      return(if (is.na(value)) NA_real_ else -value)
    }
    parse_primary()
  }
  apply_operation <- function(left, operator, right) {
    left <- finite_value(left); right <- finite_value(right)
    if (is.na(left) || is.na(right)) return(NA_real_)
    value <- switch(operator, `+` = left + right, `-` = left - right, `*` = left * right, `/` = if (right == 0) NA_real_ else left / right)
    finite_value(value)
  }
  parse_term <- function() {
    value <- parse_unary()
    while (identical(peek(), "*") || identical(peek(), "/")) {
      operator <- consume()
      value <- apply_operation(value, operator, parse_unary())
    }
    value
  }
  parse_expression <- function() {
    value <- parse_term()
    while (identical(peek(), "+") || identical(peek(), "-")) {
      operator <- consume()
      value <- apply_operation(value, operator, parse_term())
    }
    value
  }
  value <- parse_expression()
  if (token_index <= length(tokens)) stop(sprintf("Unexpected token '%s' in derived metric formula.", peek()))
  value
}

derived_metric_specs <- function(config) {
  configured <- config$derived_sleep_metrics %||% list()
  inline <- config$sleep_metrics %||% list()
  formulas <- list()
  add_formulas <- function(definitions, source_name, only_formula_definitions = FALSE) {
    if (!length(definitions)) return(invisible(NULL))
    if (!is.list(definitions) || is.null(names(definitions)) || any(!nzchar(names(definitions)))) {
      stop(sprintf("%s must be a named mapping of metric names to formulas.", source_name))
    }
    for (metric in names(definitions)) {
      definition <- definitions[[metric]]
      is_formula_definition <- is.list(definition) && !is.null(definition$formula)
      if (only_formula_definitions && !is_formula_definition) next
      formula <- if (is_formula_definition) definition$formula else definition
      if (length(formula) != 1L || is.na(formula) || !nzchar(trimws(as.character(formula)))) {
        stop(sprintf("Derived metric '%s' in %s requires a non-empty formula.", metric, source_name))
      }
      if (metric %in% names(formulas)) stop(sprintf("Derived metric '%s' is defined more than once.", metric))
      formula <- as.character(formula)
      tryCatch(evaluate_derived_formula(formula, list()), error = function(error) {
        stop(sprintf("Invalid formula for derived metric '%s': %s", metric, conditionMessage(error)))
      })
      formulas[[metric]] <<- formula
    }
    invisible(NULL)
  }
  add_formulas(configured, "derived_sleep_metrics")
  add_formulas(inline, "sleep_metrics", only_formula_definitions = TRUE)
  formulas
}

evaluate_derived_metrics <- function(source_values, base_values, derived_specs) {
  values <- source_values
  for (metric in names(base_values)) values[[metric]] <- base_values[[metric]]
  for (metric in names(derived_specs)) {
    value <- evaluate_derived_formula(derived_specs[[metric]], values)
    if (!is.na(value)) {
      values[[metric]] <- value
      base_values[[metric]] <- value
    }
  }
  base_values
}

sleep_metric_values_from_json <- function(scalar_values, specs, derived_specs) {
  source_values <- setNames(lapply(scalar_values, parse_number), names(scalar_values))
  base_values <- list()
  for (metric in names(specs)) {
    value <- json_scalar_value(scalar_values, specs[[metric]])
    if (is.null(value) && metric == "Sleep_Score") {
      value <- json_scalar_value(scalar_values, c("overallScore"))
    }
    if (is.null(value) && metric == "Sleep_Duration") {
      value <- json_scalar_value(scalar_values, c("sleepDuration", "totalSleepTime"))
    }
    if (is.null(value) && metric == "Sleep_Duration") {
      stage_values <- vapply(
        c("deepSleepSeconds", "lightSleepSeconds", "remSleepSeconds"),
        function(field) parse_number(json_scalar_value(scalar_values, field)),
        numeric(1)
      )
      if (all(is.finite(stage_values)) && sum(stage_values) > 0) value <- sum(stage_values) / 3600
    }
    if (!is.null(value)) value <- if (metric == "Sleep_Duration") duration_to_hours(value) else parse_number(value)
    if (!is.null(value) && !is.na(value)) base_values[[metric]] <- value
  }
  evaluate_derived_metrics(source_values, base_values, derived_specs)
}

find_daily_logs <- function(value) {
  if (is.list(value) && !is.null(value$dailyLogList) && is.list(value$dailyLogList)) return(value$dailyLogList)
  if (is.list(value)) for (item in value) { found <- find_daily_logs(item); if (!is.null(found)) return(found) }
  NULL
}

normalize_status <- function(value) {
  if (is.logical(value) && length(value)) return(value[1])
  text <- norm(value)
  if (text %in% TRUE_VALUES) return(TRUE)
  if (text %in% FALSE_VALUES) return(FALSE)
  NA
}

lifestyle_rows <- function(payload) {
  logs <- find_daily_logs(payload); if (is.null(logs) && is.list(payload)) logs <- payload
  rows <- list()
  for (entry in logs %||% list()) {
    if (!is.list(entry)) next
    day <- parse_date(entry$calendarDate %||% entry$date %||% entry$logDate)
    name <- trimws(as.character(entry$behaviourName %||% entry$behaviorName %||% entry$name %||% entry$label %||% ""))[1]
    status <- normalize_status(entry$status %||% entry$value)
    if (is.na(day) || !nzchar(name) || is.na(status)) next
    key <- as.character(day); if (is.null(rows[[key]])) rows[[key]] <- list()
    rows[[key]][[name]] <- isTRUE(rows[[key]][[name]] %||% FALSE) || isTRUE(status)
  }
  rows
}

materialize_source <- function(source) {
  source <- normalizePath(source, mustWork = TRUE)
  if (dir.exists(source)) {
    progress("[Lifestyle] Using folder: ", source)
    return(list(root = source, direct_json = NULL, cleanup = FALSE))
  }
  if (grepl("\\.zip$", source, ignore.case = TRUE)) {
    progress("[Lifestyle] Extracting ZIP: ", source)
    root <- tempfile("garmin_export_"); dir.create(root); utils::unzip(source, exdir = root)
    return(list(root = root, direct_json = NULL, cleanup = TRUE))
  }
  if (grepl("LifestyleLogging\\.json$", source, ignore.case = TRUE)) {
    progress("[Lifestyle] Using JSON: ", source)
    return(list(root = NULL, direct_json = source, cleanup = FALSE))
  }
  stop("Input must be a Garmin folder, ZIP archive, or LifestyleLogging.json: ", source)
}

excluded_source_directories <- c("INREACH")

source_files <- function(materialized, pattern) {
  if (is.null(materialized$root)) return(character())

  # Walk one directory at a time so excluded Garmin subtrees are never
  # traversed. list.files(..., recursive = TRUE) discovers INREACH first and
  # only allows filtering after that work has already happened.
  walk <- function(directory) {
    entries <- list.files(directory, full.names = TRUE, recursive = FALSE, include.dirs = TRUE)
    if (!length(entries)) return(character())
    is_directory <- dir.exists(entries)
    files <- entries[!is_directory & grepl(pattern, basename(entries), ignore.case = TRUE)]
    directories <- entries[is_directory & !(toupper(basename(entries)) %in% excluded_source_directories)]
    c(files, unlist(lapply(directories, walk), use.names = FALSE))
  }

  walk(materialized$root)
}

read_csv_flexible <- function(path) {
  # Count separators from raw bytes so malformed UTF-8 cannot trigger a
  # warning while determining the delimiter.
  first_raw <- tryCatch({
    bytes <- readBin(path, what = "raw", n = 1024L)
    line_end <- match(as.raw(0x0A), bytes)
    if (!is.na(line_end)) bytes[seq_len(line_end - 1L)] else bytes
  }, error = function(e) raw())
  commas <- if (length(first_raw)) sum(first_raw == charToRaw(",")) else 0L
  semicolons <- if (length(first_raw)) sum(first_raw == charToRaw(";")) else 0L
  separator <- if (semicolons > commas) ";" else ","

  # Garmin files are not consistently encoded. Try UTF-8 first, then the
  # Windows/Latin-1 fallbacks without exposing parser warnings to the caller.
  for (encoding in c("UTF-8-BOM", "windows-1252", "latin1")) {
    data <- tryCatch(
      suppressWarnings(utils::read.csv(
        path,
        sep = separator,
        check.names = FALSE,
        stringsAsFactors = FALSE,
        fileEncoding = encoding
      )),
      error = function(e) NULL
    )
    if (!is.null(data)) return(data)
  }
  NULL
}

json_named_value <- function(value, aliases) {
  if (!is.list(value)) return(NULL)
  wanted <- norm(aliases)
  for (name in names(value)) {
    if (norm(name) %in% wanted && !is.list(value[[name]])) return(value[[name]])
  }
  for (child in value) {
    found <- json_named_value(child, aliases)
    if (!is.null(found)) return(found)
  }
  NULL
}

sleep_json_value <- function(entry, metric, aliases) {
  value <- json_named_value(entry, aliases)
  if (!is.null(value)) {
    return(if (metric == "Sleep_Duration") duration_to_hours(value) else parse_number(value))
  }
  if (metric == "Sleep_Score") {
    value <- json_named_value(entry$sleepScores %||% list(), c("overallScore", "overall sleep score"))
    return(parse_number(value))
  }
  if (metric == "Sleep_Duration") {
    stages <- c(entry$deepSleepSeconds, entry$lightSleepSeconds, entry$remSleepSeconds)
    if (length(stages) == 3 && all(!vapply(stages, is.null, logical(1)))) {
      seconds <- suppressWarnings(sum(as.numeric(unlist(stages)), na.rm = TRUE))
      if (is.finite(seconds) && seconds > 0) return(seconds / 3600)
    }
  }
  NA_real_
}

sleep_rows_json <- function(materialized, specs, derived_specs) {
  json_files <- source_files(materialized, "_sleepData\\.json$")
  if (!length(json_files)) return(list())
  progress("[Lifestyle] Reading ", length(json_files), " sleep JSON file(s)...")
  result <- list()
  for (path in json_files) {
    progress("[Lifestyle] Reading sleep file: ", path)
    payload <- tryCatch(read_json(path), error = function(e) NULL)
    if (!is.list(payload)) next
    for (entry in payload) {
      if (!is.list(entry)) next
      day <- parse_date(entry$calendarDate %||% entry$date)
      if (is.na(day)) next
      key <- as.character(day); if (is.null(result[[key]])) result[[key]] <- list()
      scalar_values <- json_scalar_values(entry)
      metric_values <- sleep_metric_values_from_json(scalar_values, specs, derived_specs)
      for (metric in names(metric_values)) {
        if (is.null(result[[key]][[metric]])) result[[key]][[metric]] <- metric_values[[metric]]
      }
    }
  }
  result
}

metric_specs <- function(config) {
  configured <- config$sleep_metrics %||% names(DEFAULT_METRICS)
  if (is.list(configured) && !is.null(names(configured))) {
    inline_derived <- vapply(configured, function(definition) is.list(definition) && !is.null(definition$formula), logical(1))
    configured <- configured[!inline_derived]
    return(setNames(lapply(seq_along(configured), function(index) {
      metric <- names(configured)[index]
      aliases <- as.character(unlist(configured[[index]]))
      # A null/empty mapping means that the config key is the source field
      # name itself, e.g. `averageHR:`.
      if (!length(aliases) || !any(nzchar(aliases))) metric else aliases
    }), names(configured)))
  }
  names <- as.character(unlist(configured)); setNames(lapply(names, function(name) DEFAULT_METRICS[[name]] %||% name), names)
}

metric_directions <- function(config, metrics) {
  configured <- config$metric_directions %||% list()
  if (length(configured) && (is.null(names(configured)) || any(!nzchar(names(configured))))) {
    stop("metric_directions must be a named mapping of metric names to 'higher' or 'lower'.")
  }
  directions <- setNames(rep("higher", length(metrics)), metrics)
  known <- intersect(metrics, names(DEFAULT_METRIC_DIRECTIONS))
  directions[known] <- unname(DEFAULT_METRIC_DIRECTIONS[known])
  for (metric in names(configured)) {
    value <- tolower(trimws(as.character(configured[[metric]])))
    if (!value %in% c("higher", "lower")) {
      stop(sprintf("Invalid direction for metric '%s': use 'higher' or 'lower'.", metric))
    }
    if (metric %in% metrics) directions[[metric]] <- value
  }
  directions
}

sleep_rows <- function(materialized, specs, derived_specs) {
  result <- sleep_rows_json(materialized, specs, derived_specs)
  # Garmin's _sleepData.json files are the authoritative source. CSV files are
  # only a compatibility fallback for exports that do not contain usable JSON.
  if (length(result)) {
    progress("[Lifestyle] Using sleep JSON data; skipping CSV fallback.")
    return(result)
  }

  csv_files <- source_files(materialized, "\\.csv$")
  progress("[Lifestyle] No usable sleep JSON found; reading ", length(csv_files), " sleep CSV file(s) as fallback...")
  for (path in csv_files) {
    progress("[Lifestyle] Reading sleep file: ", path)
    data <- read_csv_flexible(path); if (is.null(data) || !nrow(data)) next
    date_candidates <- names(data)[norm(names(data)) %in% c("date", "datum", "sleep score 4 wochen", "sleep date", "calendar date")]
    if (!length(date_candidates)) next
    date_col <- date_candidates[1]
    matched <- lapply(specs, function(aliases) { columns <- names(data)[norm(names(data)) %in% norm(aliases)]; if (length(columns)) columns[1] else NA_character_ })
    if (!any(!is.na(unlist(matched)))) next
    for (i in seq_len(nrow(data))) {
      day <- parse_date(data[[date_col]][i]); if (is.na(day)) next
      key <- as.character(day); if (is.null(result[[key]])) result[[key]] <- list()
      source_values <- setNames(lapply(data[i, , drop = FALSE], parse_number), names(data))
      base_values <- list()
      for (metric in names(specs)) {
        column <- matched[[metric]]; if (is.na(column)) next
        value <- if (metric == "Sleep_Duration") duration_to_hours(data[[column]][i]) else parse_number(data[[column]][i])
        if (!is.na(value)) base_values[[metric]] <- value
      }
      metric_values <- evaluate_derived_metrics(source_values, base_values, derived_specs)
      for (metric in names(metric_values)) {
        if (is.null(result[[key]][[metric]])) result[[key]][[metric]] <- metric_values[[metric]]
      }
    }
  }
  if (!length(result)) stop("No compatible Garmin sleep JSON or CSV found. Provide a Garmin export folder/ZIP or sleep_input.")
  progress("[Lifestyle] Sleep dates loaded: ", length(result))
  result
}

group_stats <- function(values, interval) {
  values <- as.numeric(values)
  values <- values[is.finite(values)]
  if (!length(values)) return(list(n = 0, mean = NULL, median = NULL, sd = NULL, interval_low = NULL, interval_high = NULL))
  low <- (1 - interval) / 2
  list(n = length(values), mean = mean(values), median = median(values), sd = if (length(values) > 1) stats::sd(values) else NULL, interval_low = as.numeric(stats::quantile(values, low, names = FALSE)), interval_high = as.numeric(stats::quantile(values, 1 - low, names = FALSE)))
}

group_count <- function(values) list(n = length(values))

activity_comparison_results <- function(tests, lifestyle, lifestyle_keys, sleep_values, metrics, directions, config, interval, confidence, alpha) {
  if (!length(tests)) return(list())
  results <- list(); index <- 1L
  for (test in tests) {
    unlist_activity_names <- function(tree) {
      if (tree$type == "activity") return(tree$name)
      if (tree$type == "not") return(unlist_activity_names(tree$child))
      c(unlist_activity_names(tree$left), unlist_activity_names(tree$right))
    }
    activity_names <- unique(c(unlist_activity_names(test$group_a$tree), unlist_activity_names(test$group_b$tree)))
    group_a_matches <- vapply(lifestyle_keys, function(key) {
      statuses <- activity_statuses_for_day(lifestyle[[key]], activity_names, config)
      evaluate_activity_expression(test$group_a$tree, statuses)
    }, logical(1))
    group_b_matches <- vapply(lifestyle_keys, function(key) {
      statuses <- activity_statuses_for_day(lifestyle[[key]], activity_names, config)
      evaluate_activity_expression(test$group_b$tree, statuses)
    }, logical(1))
    for (metric in metrics) {
      values <- sleep_values[[metric]]; usable <- is.finite(values)
      unknown <- is.na(group_a_matches) | is.na(group_b_matches)
      overlap <- !unknown & group_a_matches & group_b_matches
      group_a_values <- values[usable & !unknown & !overlap & group_a_matches]
      group_b_values <- values[usable & !unknown & !overlap & group_b_matches]
      group_a <- group_stats(group_a_values, interval); group_b <- group_stats(group_b_values, interval)
      delta <- p_value <- ci_low <- ci_high <- NULL
      if (length(group_a_values) >= 2L && length(group_b_values) >= 2L) {
        delta <- mean(group_a_values) - mean(group_b_values)
        statistical_test <- tryCatch(
          stats::t.test(group_a_values, group_b_values, var.equal = FALSE, conf.level = confidence),
          error = function(e) NULL
        )
        if (!is.null(statistical_test)) {
          delta <- unname(statistical_test$estimate[[1]] - statistical_test$estimate[[2]])
          p_value <- unname(statistical_test$p.value)
          ci_low <- unname(statistical_test$conf.int[1]); ci_high <- unname(statistical_test$conf.int[2])
        }
      }
      significant <- isTRUE(!is.null(delta) && is.finite(delta) && !is.null(p_value) && is.finite(p_value) && p_value < alpha && delta != 0)
      direction <- directions[[metric]]
      interpretation <- if (!significant || is.null(delta) || delta == 0) "not_significant" else if ((direction == "higher" && delta > 0) || (direction == "lower" && delta < 0)) "better" else "worse"
      classification <- if (significant && interpretation == "better") "significant_positive" else if (significant && interpretation == "worse") "significant_negative" else "not_significant"
      results[[index]] <- c(
        list(test_name = test$name, group_a_label = test$group_a$label, group_a_expression = test$group_a$expression, group_b_label = test$group_b$label, group_b_expression = test$group_b$expression, metric = metric, unknown_excluded_n = sum(usable & unknown), overlap_excluded_n = sum(usable & overlap)),
        setNames(group_a, paste0("group_a_", names(group_a))),
        setNames(group_b, paste0("group_b_", names(group_b))),
        list(delta = delta, delta_ci_low = ci_low, delta_ci_high = ci_high, p_value = p_value, classification = classification, better_is = direction)
      )
      index <- index + 1L
    }
  }
  results
}

analyse <- function(config, lifestyle_materialized, sleep_materialized) {
  progress("[Lifestyle] Starting analysis...")
  start <- parse_date(config$start_date); end <- parse_date(config$end_date)
  if (is.na(start) || is.na(end) || end < start) stop("Config requires valid start_date and end_date with end_date >= start_date")
  interval <- as.numeric(config$value_interval %||% 0.80); confidence <- as.numeric(config$confidence_interval %||% config$confidence_level %||% 0.95); alpha <- as.numeric(config$significance_level %||% 0.05)
  if (!(interval > 0 && interval <= 1 && confidence > 0 && confidence < 1 && alpha > 0 && alpha < 1)) stop("Invalid value_interval, confidence_interval, or significance_level")
  performance <- config$performance %||% list()
  performance_enabled <- if (is.null(performance$enabled)) TRUE else isTRUE(performance$enabled)
  workers <- as.integer(performance$workers %||% 1L)
  backend <- tolower(as.character(performance$backend %||% "serial"))
  if (length(workers) != 1L || is.na(workers) || workers < 1L) stop("performance.workers must be a positive integer")
  if (!backend %in% c("serial", "parallel")) stop("performance.backend must be 'serial' or 'parallel'")
  if (backend == "parallel" && workers > 1L) {
    progress("[Lifestyle] Parallel backend requested; using deterministic serial execution until benchmark validation enables it.")
  }
  if (!performance_enabled) progress("[Lifestyle] Performance optimizations disabled in configuration.")
  lifestyle_files <- if (!is.null(lifestyle_materialized$direct_json)) lifestyle_materialized$direct_json else source_files(lifestyle_materialized, "LifestyleLogging\\.json$")
  if (!length(lifestyle_files)) stop("No LifestyleLogging.json found in Garmin export")
  progress("[Lifestyle] Reading ", length(lifestyle_files), " LifestyleLogging JSON file(s)...")
  lifestyle <- timed("lifestyle parsing", {
    parsed <- list()
    for (path in lifestyle_files) {
      progress("[Lifestyle] Reading lifestyle file: ", path)
      rows <- lifestyle_rows(read_json(path))
      for (key in names(rows)) {
        if (is.null(parsed[[key]])) parsed[[key]] <- list()
        entries <- rows[[key]]
        for (activity in names(entries)) parsed[[key]][[activity]] <- isTRUE(parsed[[key]][[activity]]) || isTRUE(entries[[activity]])
      }
    }
    parsed
  })
  specs <- metric_specs(config)
  derived_specs <- derived_metric_specs(config)
  metrics <- c(names(specs), names(derived_specs))
  directions <- metric_directions(config, metrics)
  sleep <- timed("sleep parsing", sleep_rows(sleep_materialized, specs, derived_specs))
  excluded <- norm(unlist(config$excluded_activities %||% list())); configured <- as.character(unlist(config$activities %||% list()))
  found <- unique(unlist(lapply(lifestyle, names))); activities <- unique(c(configured, found)); activities <- activities[!norm(activities) %in% excluded]
  configured_comparison_tests <- comparison_tests(config, activities)
  progress("[Lifestyle] Activities to analyse: ", length(activities), "; metrics: ", length(metrics))
  missing_default <- isTRUE(config$missing_activity_is_no %||% TRUE); overrides <- config$missing_activity_is_no_by_activity %||% list()
  days <- seq.Date(start, end, by = "day")
  lifestyle_keys <- format(days, "%Y-%m-%d")
  sleep_keys <- format(days + 1, "%Y-%m-%d")
  sleep_values <- setNames(lapply(metrics, function(metric) {
    vapply(sleep_keys, function(key) {
      value <- sleep[[key]][[metric]]
      if (is.null(value)) NA_real_ else as.numeric(value)
    }, numeric(1))
  }), metrics)
  results <- vector("list", length(sorted_activities <- sort(activities)) * length(metrics))
  index <- 1L
  analysis_started <- proc.time()[["elapsed"]]
  for (activity_index in seq_along(sorted_activities)) {
    activity <- sorted_activities[activity_index]
    progress("[Lifestyle] Activity ", activity_index, "/", length(sorted_activities), ": ", activity)
    status_values <- vapply(lifestyle_keys, function(key) {
      status <- lifestyle[[key]][[activity]]
      if (isTRUE(status)) TRUE else if (identical(status, FALSE)) FALSE else NA
    }, logical(1))
    for (metric in metrics) {
    direction <- directions[[metric]]
    override_name <- names(overrides)[norm(names(overrides)) == norm(activity)][1]
    missing_no <- if (length(override_name) && !is.na(override_name)) isTRUE(overrides[[override_name]]) else missing_default
    values <- sleep_values[[metric]]
    usable <- is.finite(values)
    done_values <- values[usable & status_values]
    native_not_done_values <- values[usable & !status_values & !is.na(status_values)]
    assumed_not_done_values <- if (missing_no) values[usable & is.na(status_values)] else numeric()
    not_done_values <- c(native_not_done_values, assumed_not_done_values)
    # Report descriptive statistics for each comparison group. The fields are
    # intentionally kept together so the CSV export places mean/median/sd/
    # interval directly after each group's n.
    done <- group_stats(done_values, interval)
    native_not_done <- group_count(native_not_done_values)
    assumed_not_done <- group_count(assumed_not_done_values)
    not_done <- group_stats(not_done_values, interval)
    row <- c(
      list(activity = activity, metric = metric, missing_activity_is_no = missing_no),
      setNames(done, paste0("done_", names(done))),
      setNames(native_not_done, paste0("native_not_done_", names(native_not_done))),
      setNames(assumed_not_done, paste0("assumed_not_done_", names(assumed_not_done))),
      setNames(not_done, paste0("not_done_", names(not_done)))
    )
    delta <- p_value <- ci_low <- ci_high <- NULL
    if (length(done_values) >= 2 && length(not_done_values) >= 2) {
      delta <- mean(done_values) - mean(not_done_values)
      test <- tryCatch(
        stats::t.test(done_values, not_done_values, var.equal = FALSE, conf.level = confidence),
        error = function(e) NULL
      )
      if (!is.null(test)) {
        # Use the same group estimates as the Welch test. This keeps delta
        # consistent with its confidence interval and p-value.
        delta <- unname(test$estimate[[1]] - test$estimate[[2]])
        p_value <- unname(test$p.value)
        ci_low <- unname(test$conf.int[1])
        ci_high <- unname(test$conf.int[2])
      }
    }
    significant <- isTRUE(
      !is.null(delta) && length(delta) == 1L && is.finite(delta) &&
        !is.null(p_value) && length(p_value) == 1L && is.finite(p_value) &&
        p_value < alpha && delta != 0
    )
    interpretation <- if (!significant || is.null(delta) || delta == 0) "not_significant" else if ((direction == "higher" && delta > 0) || (direction == "lower" && delta < 0)) "better" else "worse"
    # Classification CSVs describe the direction of the outcome, not the
    # native sign of delta. For metrics where lower is better (for example
    # RHR), a negative delta is therefore significant_positive.
    classification <- if (significant && interpretation == "better") "significant_positive" else if (significant && interpretation == "worse") "significant_negative" else "not_significant"
     results[[index]] <- c(row, list(delta = delta, delta_ci_low = ci_low, delta_ci_high = ci_high, p_value = p_value, significant = significant, classification = classification, better_is = direction, interpretation = interpretation)); index <- index + 1
     }
   }
  results <- Filter(Negate(is.null), results)
  progress(sprintf("[Lifestyle] Timing statistical analysis: %.3f s", proc.time()[["elapsed"]] - analysis_started))
  classifications <- if (length(results)) vapply(results, function(x) as.character(x$classification %||% "not_significant"), character(1)) else character()
  significant_count <- sum(classifications %in% c("significant_positive", "significant_negative"))
  not_significant_count <- sum(classifications == "not_significant")
  total_count <- length(classifications)
  significance_summary <- list(
    significant = significant_count,
    not_significant = not_significant_count,
    total = total_count,
    significant_percent = if (total_count) 100 * significant_count / total_count else 0,
    not_significant_percent = if (total_count) 100 * not_significant_count / total_count else 0
  )
  progress("[Lifestyle] Statistical analysis finished: ", total_count, " activity/metric combinations")
  progress(sprintf("[Lifestyle] Significance: %d significant (%.1f%%), %d not significant (%.1f%%)", significant_count, significance_summary$significant_percent, not_significant_count, significance_summary$not_significant_percent))
  interpretation_summary <- if (length(results)) table(vapply(results, function(x) as.character(x$interpretation %||% "not_significant"), character(1))) else integer()
  comparison_results <- activity_comparison_results(configured_comparison_tests, lifestyle, lifestyle_keys, sleep_values, metrics, directions, config, interval, confidence, alpha)
  if (length(configured_comparison_tests)) progress("[Lifestyle] Configured activity comparison tests: ", length(comparison_results), " test/metric combinations")
    list(metadata = list(start_date = as.character(start), end_date = as.character(end), value_interval = interval, confidence_interval = confidence, significance_level = alpha, method = "Welch two-sample t-test", descriptive_statistics = "mean, median, sd, interval_low, and interval_high are calculated separately for done and not_done; CSV fields are grouped directly after their corresponding n", delta_definition = "mean(done) - mean(not_done)", metric_direction_definition = "better_is controls whether higher or lower values are interpreted as better; configured directions are included per result", not_done_definition = "not_done = native_not_done + assumed_not_done; native_not_done is explicitly logged as false, assumed_not_done is missing and enabled by missing_activity_is_no", significance_summary = significance_summary, interpretation_summary = as.list(interpretation_summary)), results = results, comparison_results = comparison_results)
}

next_run_output_dir <- function(base_dir) {
  dir.create(base_dir, recursive = TRUE, showWarnings = FALSE)
  run_date <- format(Sys.Date(), "%Y-%m-%d")
  pattern <- paste0("^", run_date, "_Analysis_([0-9]+)$")
  existing <- list.dirs(base_dir, full.names = FALSE, recursive = FALSE)
  matching <- grep(pattern, existing, value = TRUE)
  used <- if (length(matching)) as.integer(sub(pattern, "\\1", matching)) else integer()
  file.path(base_dir, paste0(run_date, "_Analysis_", max(c(0L, used)) + 1L))
}

resolve_output_dir <- function(config_path, configured_dir) {
  if (!grepl("^([A-Za-z]:[\\\\/]|/)", configured_dir)) {
    config_dir <- basename(dirname(config_path))
    if (identical(tolower(basename(getwd())), tolower(config_dir)) &&
        startsWith(tolower(configured_dir), paste0(tolower(config_dir), "/"))) {
      return(file.path(dirname(dirname(config_path)), sub("^[^/]+/", "", configured_dir)))
    }
  }
  configured_dir
}

write_outputs <- function(result, output_dir, config) {
  output_dir <- next_run_output_dir(output_dir)
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  progress("[Lifestyle] Writing results to: ", normalizePath(output_dir, mustWork = FALSE))
  analysis_output <- config$analysis_output %||% list()
  output_enabled <- function(name) {
    value <- analysis_output[[name]]
    if (is.null(value)) return(TRUE)
    if (!is.logical(value) || length(value) != 1L || is.na(value)) {
      stop(sprintf("analysis_output.%s must be a single true/false value.", name))
    }
    isTRUE(value)
  }
  write_all_combined <- output_enabled("all_combined")
  write_all_classifications <- output_enabled("all_classifications")
  write_per_metric_combined <- output_enabled("per_metric_combined")
  write_per_metric_classifications <- output_enabled("per_metric_classifications")
  write_json_result <- output_enabled("json")
  classifications <- c("significant_positive", "significant_negative", "not_significant")
  result_columns <- if (length(result$results)) {
    unique(unlist(lapply(result$results, names), use.names = FALSE))
  } else {
    character()
  }
  csv_priority <- c("activity", "metric", "delta", "p_value", "delta_ci_low", "delta_ci_high")
  csv_columns <- c(
    intersect(csv_priority, result_columns),
    setdiff(result_columns, csv_priority)
  )
  result_frame <- function(selected, classification) {
    if (length(selected)) {
      frame <- do.call(rbind, lapply(selected, function(x) as.data.frame(lapply(x, function(v) if (is.null(v)) NA else v), stringsAsFactors = FALSE)))
    } else {
      frame <- as.data.frame(setNames(replicate(length(csv_columns), character(), simplify = FALSE), csv_columns), stringsAsFactors = FALSE)
    }
    frame
  }
  sort_frame <- function(frame, classification) {
    if (!nrow(frame)) return(frame[, csv_columns, drop = FALSE])
    deltas <- as.numeric(frame$delta)
    frame <- frame[order(is.na(deltas), if (classification == "significant_negative") deltas else -deltas, na.last = TRUE), , drop = FALSE]
    frame[, csv_columns, drop = FALSE]
  }
  write_frame <- function(frame, path, classification = "all") {
    utils::write.csv(sort_frame(frame, classification), path, row.names = FALSE, na = "")
  }

  # Convert result lists to a data frame once. All subsequent exports filter
  # this frame instead of rebuilding and coercing the same result lists.
  all_frame <- result_frame(result$results, "all")

  # Directly configured activity comparisons intentionally have their own CSV
  # so the established activity-vs-not-done files and JSON contract stay intact.
  if (length(result$comparison_results %||% list())) {
    comparison_columns <- unique(unlist(lapply(result$comparison_results, names), use.names = FALSE))
    comparison_priority <- c(
      "test_name", "metric", "delta", "p_value", "delta_ci_low", "delta_ci_high",
      "group_a_n", "group_a_mean", "group_a_median", "group_a_sd", "group_a_interval_low", "group_a_interval_high",
      "group_b_n", "group_b_mean", "group_b_median", "group_b_sd", "group_b_interval_low", "group_b_interval_high",
      "unknown_excluded_n", "overlap_excluded_n",
      "group_a_label", "group_b_label",
      "classification", "better_is",
      "group_a_expression", "group_b_expression"
    )
    comparison_columns <- c(intersect(comparison_priority, comparison_columns), setdiff(comparison_columns, comparison_priority))
    comparison_frame <- do.call(rbind, lapply(result$comparison_results, function(x) {
      as.data.frame(lapply(x, function(value) if (is.null(value)) NA else value), stringsAsFactors = FALSE)
    }))
    comparison_frame <- comparison_frame[order(as.character(comparison_frame$test_name), as.character(comparison_frame$metric)), comparison_columns, drop = FALSE]
    utils::write.csv(comparison_frame, file.path(output_dir, "activity_comparison_tests.csv"), row.names = FALSE, na = "")
  }

  # Write the all-metrics files with an explicit `all_` prefix so they cannot
  # be confused with the per-metric exports written below.
  all_metric_file_stems <- c(
    significant_positive = "all_significant_positive",
    significant_negative = "all_significant_negative",
    not_significant = "all_not_significant"
  )

  if (write_all_combined) {
    # Write one combined export containing every activity/metric result.
    write_frame(all_frame, file.path(output_dir, "all.csv"))
  }

  if (write_all_classifications) {
    for (classification in classifications) {
      selected <- if ("classification" %in% names(all_frame)) all_frame[all_frame$classification == classification, , drop = FALSE] else all_frame[FALSE, , drop = FALSE]
      write_frame(selected, file.path(output_dir, paste0(all_metric_file_stems[[classification]], ".csv")), classification)
    }
  }

  result_metrics <- vapply(result$results, function(x) as.character(x$metric %||% ""), character(1))
  configured_metrics <- c(names(metric_specs(config)), names(derived_metric_specs(config)))
  metrics <- unique(c(configured_metrics, result_metrics))
  metrics <- metrics[!is.na(metrics) & nzchar(metrics)]
  safe_metric_name <- function(metric) {
    stem <- gsub("[^A-Za-z0-9._-]+", "_", trimws(metric))
    stem <- gsub("_+", "_", stem)
    if (!nzchar(stem)) "metric" else stem
  }
  metric_stems <- make.unique(vapply(metrics, safe_metric_name, character(1)), sep = "_")
  for (metric_index in seq_along(metrics)) {
    metric <- metrics[[metric_index]]
    metric_results <- if ("metric" %in% names(all_frame)) all_frame[as.character(all_frame$metric) == metric, , drop = FALSE] else all_frame[FALSE, , drop = FALSE]
    metric_stem <- metric_stems[[metric_index]]

    if (write_per_metric_combined) {
      write_frame(metric_results, file.path(output_dir, paste0(metric_stem, "_all.csv")))
    }

    if (write_per_metric_classifications) {
      for (classification in classifications) {
        selected <- if ("classification" %in% names(metric_results)) metric_results[metric_results$classification == classification, , drop = FALSE] else metric_results[FALSE, , drop = FALSE]
        write_frame(selected, file.path(output_dir, paste0(metric_stem, "_", classification, ".csv")), classification)
      }
    }
  }
  if (write_json_result) {
    json_result <- result
    json_result$comparison_results <- NULL
    json_result$config <- config
    jsonlite::write_json(json_result, file.path(output_dir, "lifestyle_sleep_analysis.json"), auto_unbox = TRUE, pretty = TRUE, na = "null")
  }
  invisible(output_dir)
}

script_directory <- function() {
  files <- vapply(sys.frames(), function(frame) if (!is.null(frame$ofile)) frame$ofile else "", character(1))
  files <- files[nzchar(files)]
  if (length(files)) dirname(normalizePath(tail(files, 1))) else getwd()
}

find_config <- function(config_path = NULL) {
  if (!is.null(config_path) && nzchar(config_path)) return(config_path)
  candidates <- unique(c(
    file.path(script_directory(), "GarminLifestyleAnalysisConfig.yaml"),
    file.path(getwd(), "GarminLifestyleAnalysisConfig.yaml"),
    file.path(getwd(), "LifestyleLoggingAnalysis", "GarminLifestyleAnalysisConfig.yaml")
  ))
  found <- candidates[file.exists(candidates)]
  if (length(found)) return(found[1])
  stop("No GarminLifestyleAnalysisConfig.yaml found. Searched:\n", paste(candidates, collapse = "\n"))
}

run_lifestyle_analysis <- function(config_path = NULL, input_override = NULL, sleep_input_override = NULL) {
  config_path <- find_config(config_path)
  progress("[Lifestyle] Config: ", normalizePath(config_path, mustWork = TRUE))
  config <- yaml::read_yaml(config_path)
  input_path <- input_override %||% config$input_path
  sleep_input <- sleep_input_override %||% config$sleep_input
  if (is.null(input_path) || !nzchar(input_path)) stop("Set input_path in the config or provide input_override")
  if (is.null(sleep_input) || !nzchar(sleep_input)) sleep_input <- input_path
  lifestyle_source <- NULL; sleep_source <- NULL
  on.exit({
    if (!is.null(lifestyle_source) && lifestyle_source$cleanup) unlink(lifestyle_source$root, recursive = TRUE)
    if (!is.null(sleep_source) && sleep_source$cleanup && !identical(sleep_source$root, lifestyle_source$root)) unlink(sleep_source$root, recursive = TRUE)
  }, add = TRUE)
  lifestyle_source <- timed("materialization", materialize_source(input_path))
  sleep_source <- if (identical(sleep_input, input_path)) lifestyle_source else timed("sleep materialization", materialize_source(sleep_input))
  result <- timed("analysis", analyse(config, lifestyle_source, sleep_source))
  output_dir <- resolve_output_dir(config_path, config$output_dir %||% "LifestyleLoggingAnalysis/Out")
  timed("output", write_outputs(result, output_dir, config))
  progress("[Lifestyle] Analysed ", length(result$results), " activity/metric combinations")
  invisible(result)
}

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(name) { i <- match(name, args); if (is.na(i) || i == length(args)) NULL else args[i + 1] }

# With no command-line arguments, source() and plain Rscript both use automatic
# config discovery. Explicit arguments keep the CLI behaviour unchanged.
if (identical(environment(), globalenv())) {
  progress("[Lifestyle] Script loaded; preparing to run...")
  if (!length(args)) {
    run_lifestyle_analysis()
  } else {
    config_arg <- get_arg("--config") %||% get_arg("-c")
    run_lifestyle_analysis(config_arg, get_arg("--input"), get_arg("--sleep-input"))
  }
}
