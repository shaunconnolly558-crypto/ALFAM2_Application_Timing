################################################################################
# 01b_date_gap_analysis_and_recovery.R
#
# DESCRIPTION:
#   Analyses gaps from the main date selector and attempts to fill them using
#   progressively relaxed criteria. This allows the main selector to be strict
#   while providing a secondary mechanism for data completeness.
#
# STRATEGY:
#   1. Load gaps from date_selection_gaps.csv
#   2. For each gap, try progressively relaxed criteria:
#      - Level 1: Relax SMD threshold (e.g., SMD >= -5 instead of 0)
#      - Level 2: Relax temperature (e.g., 4°C instead of 5°C)
#      - Level 3: Relax rainfall (e.g., 5mm day, 20mm 72h)
#      - Level 4: Relax gap constraint (e.g., 28 days instead of 35)
#      - Level 5: Use any day in window regardless of weather (last resort)
#   3. Track which relaxation level was needed
#   4. Output recovered dates with quality flags
#
# OUTPUTS:
#   - recovered_dates.csv          : Dates recovered with relaxed criteria
#   - combined_dates_df.RData/.csv : Original + recovered dates
#   - gap_recovery_report.txt      : Detailed analysis report
#
################################################################################

# ==============================================================================
# USER SETTINGS - EDIT THIS SECTION
# ==============================================================================

# Set these paths to match your local directory structure

# --- Input paths ---
# input_dir: Where the main date selector saved its outputs
#            Should contain: selected_dates_df.RData, date_selection_gaps.csv,
#            and daily_summary_*.csv files
input_dir             <- file.path("output", "01_date_selection")

# weather_folder: Where the hourly weather Excel files are located
#                 Only needed if daily_summary files aren't available
weather_folder        <- file.path("data", "weather")

# station_metadata_xlsx: Station metadata with coordinates
station_metadata_xlsx <- file.path("data", "Station_metadata.xlsx")

# --- Output directory ---
# Where to save recovered dates and combined dataset
output_dir            <- file.path("output", "01b_gap_recovery")

# --- Original thresholds (from main script) ---
original_min_temp     <- 5
original_max_rain_day <- 3
original_max_rain_72h <- 15
original_smd_threshold <- 0
original_min_gap      <- 35

# --- Relaxation levels ---
# Each level progressively relaxes criteria
# Set to NA to skip that relaxation type

relaxation_levels <- list(
  # Level 1: Slightly relax SMD only
  list(
    name = "relaxed_smd",
    min_temp = 5,
    max_rain_day = 3,
    max_rain_72h = 15,
    smd_threshold = -2,  # Allow slightly waterlogged
    min_gap = 35
  ),

  # Level 2: Relax gap constraint
  list(
    name = "relaxed_gap",
    min_temp = 4,
    max_rain_day = 5,
    max_rain_72h = 20,
    smd_threshold = -2,
    min_gap = 28
  ),
  # Level 3: Relax temperature
  list(
    name = "relaxed_temp",
    min_temp = 4,
    max_rain_day = 3,
    max_rain_72h = 15,
    smd_threshold = -2,
    min_gap = 35
  ),

  # Level 4: Relax rainfall
  list(
    name = "relaxed_rain",
    min_temp = 4,
    max_rain_day = 5,
    max_rain_72h = 20,
    smd_threshold = -2,
    min_gap = 35
  ),

  # Level 5: Minimal constraints (last resort)
  list(
    name = "minimal",
    min_temp = 3,
    max_rain_day = 10,
    max_rain_72h = 30,
    smd_threshold = -5,
    min_gap = 21
  ),

  # Level 6: Any day in window (really last resort)
  list(
    name = "any_day",
    min_temp = -999,
    max_rain_day = 999,
    max_rain_72h = 999,
    smd_threshold = -999,
    min_gap = 14
  )
)

# --- Processing options ---
verbose            <- TRUE
max_recovery_level <- 2  # Stop at level 5; set to 6 to include "any_day"

# ==============================================================================
# PACKAGES
# ==============================================================================

required_packages <- c("readxl", "dplyr", "lubridate", "data.table", "tools")

for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
  }
}

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(lubridate)
  library(data.table)
  library(tools)
})

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

msg <- function(...) {
  if (verbose) cat(format(Sys.time(), "[%H:%M:%S]"), ..., "\n")
}

normalise_station_name <- function(x) {
  # First remove file extension (before removing dots!)
  x <- gsub("\\.(xlsx|xls|csv)$", "", x, ignore.case = TRUE)
  # Then normalise
  x <- tolower(x)
  x <- gsub("\\s+", "", x)           # Remove spaces
  x <- gsub("[_.-]", "", x)          # Remove punctuation
  x
}

# --- Spreading periods by zone (must match main script) ---
spreading_periods <- list(
  A = data.table(
    period   = c("early_season", "pre_silage", "post_first_cut", "pre_second_cut", "late_season"),
    start_md = c("01-15", "03-15", "05-15", "06-21", "08-21"),
    end_md   = c("03-15", "04-30", "06-07", "07-15", "09-30")
  ),
  B = data.table(
    period   = c("early_season", "pre_silage", "post_first_cut", "pre_second_cut", "late_season"),
    start_md = c("02-01", "03-15", "05-15", "06-21", "08-21"),
    end_md   = c("03-31", "04-30", "06-07", "07-15", "09-30")
  ),
  C = data.table(
    period   = c("early_season", "pre_silage", "post_first_cut", "pre_second_cut", "late_season"),
    start_md = c("03-01", "03-15", "05-15", "06-21", "08-21"),
    end_md   = c("04-15", "04-30", "06-07", "07-15", "09-30")
  )
)

get_earliest_with_gap <- function(dates, start_date, end_date, prev_date = NA, min_gap = 35) {
  candidates <- dates[dates >= start_date & dates <= end_date]

  if (!is.na(prev_date)) {
    candidates <- candidates[candidates >= (prev_date + days(min_gap))]
  }

  if (length(candidates) == 0) return(NA_Date_)
  min(candidates)
}

# ==============================================================================
# LOAD INPUTS
# ==============================================================================

msg("==================================================================")
msg("GAP ANALYSIS AND RECOVERY v1.0")
msg("==================================================================")

# --- Load original selected dates ---
selected_rdata <- file.path(input_dir, "selected_dates_df.RData")
selected_csv <- file.path(input_dir, "selected_dates_df.csv")

if (file.exists(selected_rdata)) {
  load(selected_rdata)
  original_dates <- as.data.table(selected_dates_df)
  msg("Loaded", nrow(original_dates), "original selected dates from RData")
} else if (file.exists(selected_csv)) {
  original_dates <- fread(selected_csv)
  msg("Loaded", nrow(original_dates), "original selected dates from CSV")
} else {
  stop("No selected_dates_df found. Run 01_date_selector_with_smd.R first.")
}

original_dates[, date := as.Date(date)]

# Validate required columns
required_cols <- c("station", "year", "date", "period")
missing_cols <- setdiff(required_cols, names(original_dates))
if (length(missing_cols) > 0) {
  stop("original_dates missing required columns: ", paste(missing_cols, collapse = ", "))
}
if (verbose) {
  msg("  Columns in original_dates:", paste(names(original_dates), collapse = ", "))
}

# --- Load gaps ---
gaps_csv <- file.path(input_dir, "date_selection_gaps.csv")
if (!file.exists(gaps_csv)) {
  stop("No gaps file found at: ", gaps_csv)
}

gaps <- fread(gaps_csv)
msg("Loaded", nrow(gaps), "gaps to analyse")

# Validate gaps columns
required_gap_cols <- c("station", "year", "period", "nitrate_zone")
missing_gap_cols <- setdiff(required_gap_cols, names(gaps))
if (length(missing_gap_cols) > 0) {
  stop("gaps file missing required columns: ", paste(missing_gap_cols, collapse = ", "))
}
if (verbose) {
  msg("  Columns in gaps:", paste(names(gaps), collapse = ", "))
}

if (nrow(gaps) == 0) {
  msg("No gaps to recover - all periods already filled!")
  msg("Exiting.")
  quit(save = "no")
}

# --- Load daily summaries if available ---
# These were saved by the main script and contain SMD calculations
daily_summaries <- list()

summary_files <- list.files(input_dir, pattern = "^daily_summary_.*\\.csv$", full.names = TRUE)
if (length(summary_files) > 0) {
  msg("Found", length(summary_files), "daily summary files")
  for (sf in summary_files) {
    st_name <- gsub("^daily_summary_|\\.csv$", "", basename(sf))
    daily_summaries[[st_name]] <- fread(sf)
    daily_summaries[[st_name]][, date := as.Date(date)]
  }
  if (verbose) {
    msg("  Daily summary keys:", paste(head(names(daily_summaries), 5), collapse = ", "), "...")
    msg("  Gap station examples:", paste(head(unique(gaps$station), 5), collapse = ", "))
    # Check columns in first summary
    first_summary <- daily_summaries[[1]]
    msg("  Daily summary columns:", paste(names(first_summary), collapse = ", "))
  }
} else {
  msg("WARNING: No daily summary files found. Will need to recalculate.")
  msg("For better performance, run main script with save_intermediates = TRUE")
}

# ==============================================================================
# ANALYSE GAPS
# ==============================================================================

msg("\n========== GAP ANALYSIS ==========")

# Summary statistics
cat("\nGaps by reason:\n")
print(table(gaps$reason))

cat("\nGaps by period:\n")
print(table(gaps$period))

cat("\nGaps by station (top 10):\n")
print(head(gaps[, .N, by = station][order(-N)], 10))

cat("\nGaps by year:\n")
print(table(gaps$year))

# ==============================================================================
# ATTEMPT RECOVERY
# ==============================================================================

msg("\n========== ATTEMPTING RECOVERY ==========")

recovered <- list()
unrecoverable <- list()

# Track which level each recovery used
recovery_stats <- data.table(
  level = character(),
  name = character(),
  n_recovered = integer()
)

for (i in seq_len(nrow(gaps))) {

  # Wrap in tryCatch to get better error messages
  tryCatch({

  gap <- gaps[i]

  st <- gap$station
  yr <- gap$year
  period <- gap$period
  nz <- gap$nitrate_zone

  if (verbose && i %% 50 == 1) {
    msg("Processing gap", i, "/", nrow(gaps), ":", st, yr, period)
  }

  # Debug: Show matching info for first gap
  if (i == 1 && verbose) {
    msg("  Debug - Station from gap:", st)
    msg("  Debug - Year from gap:", yr)
    msg("  Debug - Period from gap:", period)
    msg("  Debug - Nitrate zone:", nz)
    msg("  Debug - Stations in original_dates:", paste(head(unique(original_dates$station), 3), collapse = ", "), "...")
    msg("  Debug - Daily summary keys:", paste(head(names(daily_summaries), 3), collapse = ", "), "...")
  }

  # Get the period window
  sp <- spreading_periods[[nz]]

  # Check sp is valid
  if (is.null(sp) || !is.data.table(sp) || nrow(sp) == 0) {
    warning("Invalid spreading_periods for zone: ", nz)
    unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
    unrecoverable[[length(unrecoverable)]]$recovery_reason <- "invalid_zone"
    next
  }

  target_period <- gap$period  # Store in separate variable to avoid column name conflict
  period_row <- sp[period == target_period]

  if (nrow(period_row) == 0) {
    unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
    unrecoverable[[length(unrecoverable)]]$recovery_reason <- "period_not_found"
    next
  }

  window_start <- as.Date(paste0(yr, "-", period_row$start_md))
  window_end <- as.Date(paste0(yr, "-", period_row$end_md))

  # Get daily summary for this station
  # Need to match station name from gap (e.g., "Ballyhaise.xlsx") to
  # daily summary key (e.g., "Ballyhaise" from "daily_summary_Ballyhaise.csv")
  st_key <- normalise_station_name(st)

  daily <- NULL
  for (key in names(daily_summaries)) {
    key_norm <- normalise_station_name(key)
    if (key_norm == st_key) {
      daily <- daily_summaries[[key]]
      break
    }
  }

  # If not found by exact match, try partial matching
  if (is.null(daily)) {
    for (key in names(daily_summaries)) {
      key_norm <- normalise_station_name(key)
      # Check if one contains the other
      if (grepl(st_key, key_norm, fixed = TRUE) || grepl(key_norm, st_key, fixed = TRUE)) {
        daily <- daily_summaries[[key]]
        if (verbose) msg("  Matched", st, "to daily summary:", key)
        break
      }
    }
  }

  if (is.null(daily)) {
    # Try to find weather file and load it
    weather_file <- list.files(weather_folder, pattern = paste0("^", gsub("xlsx$", "", st)),
                               full.names = TRUE, ignore.case = TRUE)[1]
    if (!is.na(weather_file) && file.exists(weather_file)) {
      # Would need to recalculate - mark as unrecoverable for now
      unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
      unrecoverable[[length(unrecoverable)]]$recovery_reason <- "no_daily_summary"
    } else {
      unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
      unrecoverable[[length(unrecoverable)]]$recovery_reason <- "no_weather_data"
    }
    next
  }

  # Validate daily has required columns
  required_daily_cols <- c("date", "year", "mean_temp", "total_rain", "rain_next72", "smd")
  if (!all(required_daily_cols %in% names(daily))) {
    missing <- setdiff(required_daily_cols, names(daily))
    if (verbose && i == 1) {
      msg("  WARNING: Daily summary missing columns:", paste(missing, collapse = ", "))
      msg("  Available columns:", paste(names(daily), collapse = ", "))
    }
    unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
    unrecoverable[[length(unrecoverable)]]$recovery_reason <- "daily_summary_missing_columns"
    next
  }

  # Filter to this year and window
  daily_yr <- daily[year == yr & date >= window_start & date <= window_end]

  if (nrow(daily_yr) == 0) {
    unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
    unrecoverable[[length(unrecoverable)]]$recovery_reason <- "no_data_in_window"
    next
  }

  # Get previous date for gap constraint
  # Find most recent selected date before this period (original or recovered)

  # Start with original dates for this station/year
  orig_prev <- original_dates[station == st & year == yr & date < window_start]
  if (nrow(orig_prev) > 0) {
    prev_dates <- orig_prev$date
  } else {
    prev_dates <- as.Date(character(0))
  }

  # Add any recovered dates so far (if any exist)
  if (length(recovered) > 0) {
    recovered_so_far <- rbindlist(recovered, fill = TRUE)
    if (nrow(recovered_so_far) > 0 && "station" %in% names(recovered_so_far) && "date" %in% names(recovered_so_far)) {
      recovered_prev <- recovered_so_far[station == st & year == yr & date < window_start]
      if (nrow(recovered_prev) > 0) {
        prev_dates <- c(prev_dates, recovered_prev$date)
      }
    }
  }

  if (length(prev_dates) > 0) {
    prev_date <- max(prev_dates)
  } else {
    prev_date <- NA
  }

  # Try each relaxation level
  recovered_date <- NA
  recovery_level <- NA
  recovery_name <- NA

  for (lvl in seq_len(min(max_recovery_level, length(relaxation_levels)))) {
    rl <- relaxation_levels[[lvl]]

    # Apply relaxed criteria (with NA handling)
    # First filter rows, then extract date column
    valid_rows <- daily_yr[
      !is.na(mean_temp) & mean_temp >= rl$min_temp &
      !is.na(total_rain) & total_rain <= rl$max_rain_day &
      !is.na(rain_next72) & rain_next72 <= rl$max_rain_72h &
      !is.na(smd) & smd >= rl$smd_threshold
    ]

    # Extract dates as a vector (handles empty case safely)
    if (nrow(valid_rows) > 0) {
      valid <- valid_rows$date
    } else {
      valid <- as.Date(character(0))  # Empty date vector
    }

    # Try to find a date with gap constraint
    candidate <- get_earliest_with_gap(valid, window_start, window_end,
                                       prev_date, min_gap = rl$min_gap)

    if (!is.na(candidate)) {
      recovered_date <- candidate
      recovery_level <- lvl
      recovery_name <- rl$name
      break
    }
  }

  if (!is.na(recovered_date)) {
    recovered[[paste0(st, "_", yr, "_", period)]] <- data.table(
      station = st,
      year = yr,
      period = period,
      date = recovered_date,
      nitrate_zone = nz,
      recovery_level = recovery_level,
      recovery_name = recovery_name,
      original_gap_reason = gap$reason
    )
  } else {
    unrecoverable[[paste0(st, "_", yr, "_", period)]] <- copy(gap)
    unrecoverable[[length(unrecoverable)]]$recovery_reason <- "no_valid_dates_any_level"
  }

  }, error = function(e) {
    # Log the error with context
    msg("ERROR processing gap", i, ":", st, yr, period)
    msg("  Error message:", conditionMessage(e))
    unrecoverable[[paste0(st, "_", yr, "_", period)]] <<- copy(gap)
    unrecoverable[[length(unrecoverable)]]$recovery_reason <<- paste0("error: ", conditionMessage(e))
  })

}

# ==============================================================================
# COMBINE RESULTS
# ==============================================================================

msg("\n========== RECOVERY RESULTS ==========")

if (length(recovered) > 0) {
  recovered_df <- rbindlist(recovered)
  recovered_df[, date := as.Date(date)]
  msg("Recovered:", nrow(recovered_df), "dates")

  # Recovery level breakdown
  cat("\nRecovered by level:\n")
  if ("recovery_level" %in% names(recovered_df) && "recovery_name" %in% names(recovered_df) && nrow(recovered_df) > 0) {
    print(recovered_df[, .N, by = .(recovery_level, recovery_name)][order(recovery_level)])
  } else {
    cat("  (unable to show breakdown - missing columns)\n")
    cat("  Columns available:", paste(names(recovered_df), collapse = ", "), "\n")
  }
} else {
  recovered_df <- data.table()
  msg("No dates recovered")
}

if (length(unrecoverable) > 0) {
  unrecoverable_df <- rbindlist(unrecoverable, fill = TRUE)
  msg("Unrecoverable:", nrow(unrecoverable_df), "gaps")

  cat("\nUnrecoverable by reason:\n")
  if ("recovery_reason" %in% names(unrecoverable_df) && nrow(unrecoverable_df) > 0) {
    print(table(unrecoverable_df$recovery_reason))
  } else {
    cat("  (unable to show breakdown)\n")
  }
} else {
  unrecoverable_df <- data.table()
  msg("All gaps recovered!")
}

# ==============================================================================
# CREATE COMBINED DATASET
# ==============================================================================

msg("\n========== CREATING COMBINED DATASET ==========")

# Add quality flag to original dates
original_dates[, quality := "primary"]
original_dates[, recovery_level := 0L]
original_dates[, recovery_name := NA_character_]

if (nrow(recovered_df) > 0) {
  # Add quality flag to recovered dates
  recovered_df[, quality := "recovered"]

  # Add missing columns from original
  if (!"drainage_class" %in% names(recovered_df)) {
    recovered_df[, drainage_class := NA_character_]
  }

  # Ensure same columns - use explicit column selection
  common_cols <- intersect(names(original_dates), names(recovered_df))

  if (length(common_cols) > 0) {
    # Select columns explicitly
    orig_subset <- original_dates[, common_cols, with = FALSE]
    rec_subset <- recovered_df[, common_cols, with = FALSE]
    combined_dates_df <- rbind(orig_subset, rec_subset, fill = TRUE)
  } else {
    warning("No common columns between original and recovered dates")
    combined_dates_df <- original_dates
  }
} else {
  combined_dates_df <- original_dates
}

setorder(combined_dates_df, station, date)

msg("Combined dataset:", nrow(combined_dates_df), "dates")
msg("  Primary:", sum(combined_dates_df$quality == "primary", na.rm = TRUE))
msg("  Recovered:", sum(combined_dates_df$quality == "recovered", na.rm = TRUE))

# Validate combined_dates_df has required columns
if (!all(c("station", "date", "period", "quality") %in% names(combined_dates_df))) {
  warning("Combined dataset missing expected columns. Available: ", paste(names(combined_dates_df), collapse = ", "))
}

# ==============================================================================
# COVERAGE ANALYSIS
# ==============================================================================

msg("\n========== COVERAGE ANALYSIS ==========")

# What percentage of possible slots are filled?
n_stations <- uniqueN(c(gaps$station, original_dates$station))
n_years <- length(unique(c(gaps$year, original_dates$year)))
n_periods <- 5
max_possible <- n_stations * n_years * n_periods

coverage_pct <- (nrow(combined_dates_df) / max_possible) * 100

msg("Coverage:", round(coverage_pct, 1), "% of possible station/year/period combinations")

# Breakdown by period
cat("\nFinal coverage by period:\n")
if ("period" %in% names(combined_dates_df) && nrow(combined_dates_df) > 0) {
  coverage_by_period <- combined_dates_df[, .N, by = period]
  print(coverage_by_period)
} else {
  cat("  (no data to show)\n")
}

# Stations with lowest coverage
cat("\nStations with lowest coverage:\n")
if ("station" %in% names(combined_dates_df) && nrow(combined_dates_df) > 0) {
  station_coverage <- combined_dates_df[, .N, by = station]
  print(head(station_coverage[order(N)], 10))
} else {
  cat("  (no data to show)\n")
}

# ==============================================================================
# SAVE OUTPUTS
# ==============================================================================

msg("\n========== SAVING OUTPUTS ==========")

# --- Recovered dates only ---
if (nrow(recovered_df) > 0) {
  recovered_csv <- file.path(output_dir, "recovered_dates.csv")
  fwrite(recovered_df, recovered_csv)
  msg("Saved:", recovered_csv)
}

# --- Unrecoverable gaps ---
if (nrow(unrecoverable_df) > 0) {
  unrecoverable_csv <- file.path(output_dir, "unrecoverable_gaps.csv")
  fwrite(unrecoverable_df, unrecoverable_csv)
  msg("Saved:", unrecoverable_csv)
}

# --- Combined dataset ---
combined_rdata <- file.path(output_dir, "combined_dates_df.RData")
save(combined_dates_df, file = combined_rdata)
msg("Saved:", combined_rdata)

combined_csv <- file.path(output_dir, "combined_dates_df.csv")
fwrite(combined_dates_df, combined_csv)
msg("Saved:", combined_csv)

# --- Detailed report ---
report_txt <- file.path(output_dir, "gap_recovery_report.txt")
sink(report_txt)
cat("GAP RECOVERY REPORT\n")
cat("Generated:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("================================================================\n\n")

cat("SUMMARY:\n")
cat("  Original selected dates:", nrow(original_dates), "\n")
cat("  Gaps identified:", nrow(gaps), "\n")
cat("  Dates recovered:", nrow(recovered_df), "\n")
cat("  Unrecoverable gaps:", nrow(unrecoverable_df), "\n")
cat("  Final combined dates:", nrow(combined_dates_df), "\n")
cat("  Coverage:", round(coverage_pct, 1), "%\n\n")

cat("RECOVERY LEVEL BREAKDOWN:\n")
if (nrow(recovered_df) > 0) {
  cat("(Lower level = stricter criteria, higher quality)\n\n")
  for (lvl in seq_len(length(relaxation_levels))) {
    rl <- relaxation_levels[[lvl]]
    n <- sum(recovered_df$recovery_level == lvl, na.rm = TRUE)
    cat(sprintf("  Level %d (%s): %d dates\n", lvl, rl$name, n))
    cat(sprintf("    Criteria: temp >= %d°C, rain <= %dmm, rain72h <= %dmm, SMD >= %dmm, gap >= %d days\n",
                rl$min_temp, rl$max_rain_day, rl$max_rain_72h, rl$smd_threshold, rl$min_gap))
  }
}

cat("\n\nUNRECOVERABLE GAP REASONS:\n")
if (nrow(unrecoverable_df) > 0) {
  print(table(unrecoverable_df$recovery_reason))
} else {
  cat("  None - all gaps recovered!\n")
}

cat("\n\nFINAL COVERAGE BY PERIOD:\n")
if ("period" %in% names(combined_dates_df) && nrow(combined_dates_df) > 0) {
  print(combined_dates_df[, .N, by = period][order(period)])
} else {
  cat("  (no data)\n")
}

cat("\n\nFINAL COVERAGE BY YEAR:\n")
if ("year" %in% names(combined_dates_df) && nrow(combined_dates_df) > 0) {
  print(table(combined_dates_df$year))
} else {
  cat("  (no data)\n")
}

cat("\n\nQUALITY DISTRIBUTION:\n")
if ("quality" %in% names(combined_dates_df) && nrow(combined_dates_df) > 0) {
  print(table(combined_dates_df$quality))
} else {
  cat("  (no data)\n")
}

sink()
msg("Saved:", report_txt)

# ==============================================================================
# COMPLETION
# ==============================================================================

msg("\n========== COMPLETE ==========")
msg("Combined dataset ready:", combined_rdata)
msg("Coverage:", round(coverage_pct, 1), "%")
msg("")
msg("Next steps:")
msg("  1. Review gap_recovery_report.txt for quality assessment")
msg("  2. Decide whether to use combined_dates_df.RData or selected_dates_df.RData")
msg("     - Use combined for maximum coverage (includes recovered dates)")
msg("     - Use selected for highest quality (primary dates only)")
msg("  3. Run scenario generator with your chosen dataset")
msg("==============================")

# --- Print user decision prompt ---
cat("\n")
cat("================================================================\n")
cat("DECISION REQUIRED\n")
cat("================================================================\n")
cat("\n")
cat("You now have two datasets to choose from:\n")
cat("\n")
cat("1. selected_dates_df.RData (", nrow(original_dates), " dates)\n", sep = "")
cat("   - Only dates meeting strict criteria\n")
cat("   - Highest confidence in spreading conditions\n")
cat("   - May have gaps in coverage\n")
cat("\n")
cat("2. combined_dates_df.RData (", nrow(combined_dates_df), " dates)\n", sep = "")
cat("   - Includes recovered dates with relaxed criteria\n")
cat("   - Better coverage (", round(coverage_pct, 1), "%)\n", sep = "")
cat("   - Quality flag indicates reliability\n")
cat("\n")
cat("For your research, consider:\n")
cat("  - If testing parameter set validity: use strict (selected_dates_df)\n")
cat("  - If maximising sample size: use combined (combined_dates_df)\n")
cat("  - You can filter combined by quality == 'primary' to get strict set\n")
cat("\n")
cat("================================================================\n")
