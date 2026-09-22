#!/usr/bin/env Rscript

# Focused regression tests for the safe, declarative direct-comparison rules.
analysis <- new.env(parent = globalenv())
sys.source("lifestyle_sleep_analysis.R", envir = analysis)

expect <- function(condition, message) if (!isTRUE(condition)) stop(message, call. = FALSE)
expect_error <- function(expression, message) {
  failed <- inherits(try(force(expression), silent = TRUE), "try-error")
  expect(failed, message)
}

known <- c("Display 1h", "Display 30m", "Read")
tree <- analysis$parse_activity_expression("`Display 1h` OR `Display 30m` AND NOT `Read`", known)
statuses <- c("display 1h" = TRUE, "display 30m" = FALSE, read = FALSE)
expect(isTRUE(analysis$evaluate_activity_expression(tree, statuses)), "NOT/AND/OR precedence is incorrect.")
tree <- analysis$parse_activity_expression("(`Display 1h` OR `Display 30m`) AND `Read`", known)
expect(identical(analysis$evaluate_activity_expression(tree, statuses), FALSE), "Parentheses are not respected.")
expect_error(analysis$parse_activity_expression("`Unknown`", known), "Unknown activities must be rejected.")
expect_error(analysis$parse_activity_expression("`Display 1h` XOR `Read`", known), "Unsupported syntax must be rejected.")

config <- list(
  missing_activity_is_no = FALSE,
  activity_comparison_tests = list(list(
    name = "1h versus only 30m",
    group_a = list(expression = "`Display 1h` AND `Display 30m`"),
    group_b = list(expression = "`Display 30m` AND NOT `Display 1h`")
  )))
tests <- analysis$comparison_tests(config, known)
days <- sprintf("2026-01-%02d", 1:5)
lifestyle <- list(
  "2026-01-01" = list("Display 1h" = TRUE, "Display 30m" = TRUE),
  "2026-01-02" = list("Display 1h" = TRUE, "Display 30m" = TRUE),
  "2026-01-03" = list("Display 1h" = FALSE, "Display 30m" = TRUE),
  "2026-01-04" = list("Display 1h" = FALSE, "Display 30m" = TRUE),
  "2026-01-05" = list("Display 30m" = TRUE)
)
results <- analysis$activity_comparison_results(tests, lifestyle, days, list(Sleep_Score = c(90, 88, 80, 78, 76)), "Sleep_Score", c(Sleep_Score = "higher"), config, 0.80, 0.95, 0.05)
result <- results[[1]]
expect(identical(result$group_a_n, 2L) && identical(result$group_b_n, 2L), "Nested groups were not separated correctly.")
expect(identical(result$unknown_excluded_n, 1L), "Unknown comparisons must be excluded when missing_activity_is_no is false.")

config$missing_activity_is_no <- TRUE
results <- analysis$activity_comparison_results(tests, lifestyle, days, list(Sleep_Score = c(90, 88, 80, 78, 76)), "Sleep_Score", c(Sleep_Score = "higher"), config, 0.80, 0.95, 0.05)
expect(identical(results[[1]]$group_b_n, 3L) && identical(results[[1]]$unknown_excluded_n, 0L), "Missing activity handling must follow the global setting.")

config$activity_comparison_tests[[1]]$group_a$expression <- "`Display 1h`"
config$activity_comparison_tests[[1]]$group_b$expression <- "`Display 30m`"
overlap_test <- analysis$comparison_tests(config, known)
overlap_result <- analysis$activity_comparison_results(overlap_test, lifestyle, days, list(Sleep_Score = c(90, 88, 80, 78, 76)), "Sleep_Score", c(Sleep_Score = "higher"), config, 0.80, 0.95, 0.05)[[1]]
expect(identical(overlap_result$overlap_excluded_n, 2L), "Overlapping nights must be excluded from both groups.")

output_result <- list(
  results = list(list(activity = "Existing activity", metric = "Sleep_Score", delta = 1, p_value = 0.04, delta_ci_low = 0.1, delta_ci_high = 1.9, classification = "significant_positive", interpretation = "better")),
  comparison_results = list(overlap_result),
  metadata = list()
)
output_config <- c(config, list(analysis_output = list(all_combined = FALSE, all_classifications = FALSE, per_metric_combined = FALSE, per_metric_classifications = FALSE, json = TRUE)))
output_dir <- analysis$write_outputs(output_result, tempfile("activity-comparison-output-"), output_config)
expect(file.exists(file.path(output_dir, "activity_comparison_tests.csv")), "Configured comparisons must produce their separate CSV.")
json_text <- paste(readLines(file.path(output_dir, "lifestyle_sleep_analysis.json"), warn = FALSE), collapse = "\n")
expect(!grepl("comparison_results", json_text, fixed = TRUE), "Existing JSON structure must not include comparison results.")

cat("activity comparison tests passed\n")
