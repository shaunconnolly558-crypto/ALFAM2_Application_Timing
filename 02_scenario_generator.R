################################################################################
# 02_scenario_generator.R
#
# PURPOSE: Create ALFAM2 scenarios for time-of-day analysis
#          Each selected date gets 3 scenarios: morning, afternoon, evening
#
# DESIGN DECISIONS:
#   - Application method: Fixed from slurry_baseline.xlsx (not varied)
#   - Weather: Actual observed hourly data (not perturbed)
#   - Time blocks: 07:00, 13:00, 19:00
#   - Simulation duration: 168 hours (7 days) per scenario
#
# INPUT:  selected_dates.csv (from 01_date_selector_with_smd.R)
# OUTPUT: scenarios.csv + 168-hour weather slices for each scenario
################################################################################

# ========================== LOAD PACKAGES ====================================
# Auto-install missing packages

required_packages <- c("data.table", "readxl", "lubridate", "zoo", "tools")

cat("Checking required packages...\n")
for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    cat(sprintf("  Installing %s...\n", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
  }
}

# Load packages
suppressPackageStartupMessages({
  library(data.table)
  library(readxl)
  library(lubridate)
  library(zoo)
  library(tools)
})
cat("All packages loaded successfully.\n\n")

# ========================== USER CONFIGURATION ===============================
# MODIFY THESE PATHS TO MATCH YOUR SYSTEM

# Input paths
selected_dates_path <- file.path("output", "01_date_selection", "selected_dates_df.csv")
weather_folder      <- file.path("data", "weather")
slurry_baseline     <- file.path("data", "Slurry_Baseline.xlsx")

# Output directory
output_dir          <- file.path("output", "02_scenario_generation")

# ========================== TIME OF DAY SETTINGS =============================
# Three application times for farmer guidance
# These represent realistic farm working hours

TIME_BLOCKS <- data.table(
  time_label = c("morning", "afternoon", "evening"),
  start_time = c("07:00", "13:00", "19:00"),
  description = c(
    "Early morning: cool temps, high RH, dew present",
    "Mid-afternoon: peak temps, lowest RH, max volatilisation",
    "Evening: cooling temps, rising RH, overnight stability"
  )
)

# Weather slice duration (hours post-application)
SLICE_DURATION_HOURS <- 168  # 7 days

# Maximum gap in weather data to interpolate
MAX_GAP_HOURS <- 3

# ========================== HELPER FUNCTIONS ==================================

msg <- function(...) {

  cat("[", format(Sys.time(), "%H:%M:%S"), "]", ..., "\n")
}

#' Normalize station name for matching
#' Removes ALL non-alphanumeric characters so:
#' "Cork Airport" -> "corkairport"
#' "Cork_Airport.xlsx" -> "corkairport"
#' "Johnstown Castle" -> "johnstowncastle"
#' "Johnstown_Castle.xlsx" -> "johnstowncastle"
normalize_station_name <- function(x) {
  x <- tolower(x)
  x <- gsub("\\.(xlsx?|csv)$", "", x, ignore.case = TRUE)  # Remove file extension
  x <- gsub("[^a-z0-9]", "", x)  # Remove ALL non-alphanumeric (spaces, underscores, dots, hyphens)
  return(x)
}

#' Load and standardise weather file
#'
#' @param filepath Path to weather file
#' @return data.table with datetime, air.temp, rain.rate, wind.2m or NULL if error
load_weather_file <- function(filepath) {
  tryCatch({
    ext <- tolower(tools::file_ext(filepath))
    if (ext == "csv") {
      dt <- fread(filepath, showProgress = FALSE)
    } else {
      dt <- as.data.table(read_excel(filepath))
    }
    setnames(dt, tolower(gsub("\\s+", "", names(dt))))

    # Find datetime column
    datetime_cols <- c("datetime", "date_time", "time", "timestamp")
    dt_col <- intersect(datetime_cols, names(dt))[1]
    if (is.na(dt_col)) return(NULL)

    if (!inherits(dt[[dt_col]], "POSIXct")) {
      dt[, (dt_col) := as.POSIXct(get(dt_col), tz = "Europe/Dublin")]
    }
    setnames(dt, dt_col, "datetime")

    # Find weather columns
    temp_cols <- c("air_temp", "air.temp", "temp", "temperature", "airtemp")
    rain_cols <- c("rain_rate", "rain.rate", "rain", "precipitation", "pr")
    wind_cols <- c("wind.2m", "wind2m", "wind_2m", "wind", "windspeed")

    temp_col <- intersect(temp_cols, names(dt))[1]
    rain_col <- intersect(rain_cols, names(dt))[1]
    wind_col <- intersect(wind_cols, names(dt))[1]

    if (any(is.na(c(temp_col, rain_col, wind_col)))) return(NULL)

    setnames(dt, c(temp_col, rain_col, wind_col), c("air.temp", "rain.rate", "wind.2m"))

    dt[, air.temp := as.numeric(air.temp)]
    dt[, rain.rate := as.numeric(rain.rate)]
    dt[, wind.2m := as.numeric(wind.2m)]

    setkeyv(dt, "datetime")
    return(dt[, .(datetime, air.temp, rain.rate, wind.2m)])

  }, error = function(e) {
    return(NULL)
  })
}

#' Extract 168-hour weather slice starting at application time
#'
#' @param weather_dt Full weather data.table
#' @param app_datetime Application start time (POSIXct)
#' @param max_gap Maximum hours of NA to interpolate
#' @return List with success flag, data or reason for failure
extract_weather_slice <- function(weather_dt, app_datetime, max_gap = 3) {
  end_datetime <- app_datetime + hours(SLICE_DURATION_HOURS - 1)

  # Extract slice
  slice <- weather_dt[datetime >= app_datetime & datetime <= end_datetime]

  if (nrow(slice) < SLICE_DURATION_HOURS) {
    return(list(
      success = FALSE,
      reason = paste0("insufficient_data_", nrow(slice), "_of_", SLICE_DURATION_HOURS)
    ))
  }

  # Take first 168 rows if we have more
  if (nrow(slice) > SLICE_DURATION_HOURS) {
    slice <- slice[1:SLICE_DURATION_HOURS]
  }

  # Add ctime (hours since application)
  slice[, ctime := as.integer(difftime(datetime, app_datetime, units = "hours"))]

  # Check ctime sequence
  expected_ctime <- 0:(SLICE_DURATION_HOURS - 1)
  if (!all(slice$ctime == expected_ctime)) {
    # Try to fix gaps by deduplication
    slice <- unique(slice, by = "datetime")
    if (nrow(slice) < SLICE_DURATION_HOURS) {
      return(list(success = FALSE, reason = "gaps_in_sequence"))
    }
    slice <- slice[1:SLICE_DURATION_HOURS]
    slice[, ctime := expected_ctime]
  }

  # Interpolate small gaps in weather variables
  weather_vars <- c("air.temp", "rain.rate", "wind.2m")
  for (col in weather_vars) {
    na_count <- sum(is.na(slice[[col]]))
    if (na_count > 0) {
      # Check for maximum run length of NAs
      rle_na <- rle(is.na(slice[[col]]))
      max_run <- max(ifelse(rle_na$values, rle_na$lengths, 0))

      if (max_run > max_gap) {
        return(list(
          success = FALSE,
          reason = paste0("gap_too_large_", col, "_", max_run, "_hours")
        ))
      }

      # Interpolate
      slice[[col]] <- zoo::na.approx(slice[[col]], na.rm = FALSE)

      # Fill any remaining edge NAs
      if (any(is.na(slice[[col]]))) {
        slice[[col]] <- zoo::na.locf(slice[[col]], na.rm = FALSE, fromLast = TRUE)
        slice[[col]] <- zoo::na.locf(slice[[col]], na.rm = FALSE)
      }
    }
  }

  # Final check for any remaining NAs
  if (any(is.na(slice[, .(air.temp, rain.rate, wind.2m)]))) {
    return(list(success = FALSE, reason = "na_after_interpolation"))
  }

  return(list(success = TRUE, data = slice))
}

#' Write weather slice to CSV
write_slice_csv <- function(slice_dt, outpath) {
  out <- copy(slice_dt)[, .(
    datetime = format(datetime, "%Y-%m-%dT%H:%M:%S"),
    ctime,
    air.temp = round(air.temp, 2),
    rain.rate = round(rain.rate, 3),
    wind.2m = round(wind.2m, 2)
  )]
  fwrite(out, outpath)
}

# ========================== MAIN EXECUTION ====================================

msg("=" |> rep(70) |> paste(collapse = ""))
msg("ALFAM2 SCENARIO GENERATOR")
msg("Time-of-Day Analysis")
msg("=" |> rep(70) |> paste(collapse = ""))

# Create output directories
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
weather_slices_dir <- file.path(output_dir, "weather_slices")
dir.create(weather_slices_dir, recursive = TRUE, showWarnings = FALSE)

msg("Output directory:", output_dir)

# -------------------- Load Selected Dates ------------------------------------
msg("\n[STEP 1] Loading selected dates...")

if (!file.exists(selected_dates_path)) {
  # Try RData format
  rdata_path <- gsub("\\.csv$", ".RData", selected_dates_path)
  if (file.exists(rdata_path)) {
    load(rdata_path)
    selected_dates <- as.data.table(selected_dates_df)
  } else {
    stop("Selected dates file not found: ", selected_dates_path)
  }
} else {
  selected_dates <- fread(selected_dates_path)
}

setnames(selected_dates, tolower(gsub("\\s+", "", names(selected_dates))))

# Ensure date is Date type
if (!inherits(selected_dates$date, "Date")) {
  selected_dates[, date := as.Date(date)]
}

# Ensure station_key is normalized (or create it from station column)
if ("station_key" %in% names(selected_dates)) {
  # Re-normalize to ensure consistency with weather file lookup
  selected_dates[, station_key := normalize_station_name(station_key)]
} else if ("station" %in% names(selected_dates)) {
  # Create station_key from station name
  selected_dates[, station_key := normalize_station_name(station)]
} else {
  stop("Selected dates must have either 'station' or 'station_key' column")
}

msg("Loaded", nrow(selected_dates), "selected dates")
msg("Stations:", uniqueN(selected_dates$station_key))
msg("Station keys:", paste(sort(unique(selected_dates$station_key)), collapse = ", "))
msg("Year range:", min(selected_dates$year), "-", max(selected_dates$year))

# -------------------- Load Slurry Baseline -----------------------------------
msg("\n[STEP 2] Loading slurry baseline...")

if (!file.exists(slurry_baseline)) {
  stop("Slurry baseline file not found: ", slurry_baseline)
}

slb <- as.data.table(read_excel(slurry_baseline)[1, ])
setnames(slb, tolower(gsub("\\s+", "", names(slb))))

# Handle TAN.app variants
tan_variants <- c("tan.app", "tanapp", "tan_app")
tan_found <- intersect(tan_variants, names(slb))
if (length(tan_found) > 0 && tan_found[1] != "tan.app") {
  setnames(slb, tan_found[1], "tan.app")
}

# Get application method
app_method <- if ("app.mthd" %in% names(slb)) {
  as.character(slb$app.mthd[1])
} else {
  "ts"  # Default to trailing shoe
}

msg("Application method (fixed):", app_method)
msg("Slurry properties:")
msg("  DM:", slb$man.dm[1], "%")
msg("  pH:", slb$man.ph[1])
msg("  App rate:", slb$app.rate[1], "t/ha")
msg("  TAN applied:", slb$tan.app[1], "kg N/ha")

# -------------------- Index Weather Files ------------------------------------
msg("\n[STEP 3] Indexing weather files...")

weather_files <- list.files(weather_folder, pattern = "\\.(xlsx?|csv)$",
                            full.names = TRUE, ignore.case = TRUE)

if (length(weather_files) == 0) {
  stop("No weather files found in: ", weather_folder)
}

# Create lookup by station key - use normalization to match metadata
weather_lookup <- data.table(
  filepath = weather_files,
  filename = basename(weather_files),
  station_key = normalize_station_name(basename(weather_files))
)
setkey(weather_lookup, station_key)

msg("Found", nrow(weather_lookup), "weather files")

# Debug: Show available station keys with original filenames
msg("\nWeather files and their normalized keys:")
for (i in seq_len(nrow(weather_lookup))) {
  msg(sprintf("  %-30s -> %s", weather_lookup$filename[i], weather_lookup$station_key[i]))
}

# -------------------- Load Weather Data --------------------------------------
msg("\n[STEP 4] Loading weather data...")

# Get unique stations needed
stations_needed <- unique(selected_dates$station_key)
weather_available <- unique(weather_lookup$station_key)

# Show matching summary
matched <- intersect(stations_needed, weather_available)
unmatched_dates <- setdiff(stations_needed, weather_available)
unmatched_weather <- setdiff(weather_available, stations_needed)

msg("Station matching summary:")
msg("  Stations in selected_dates:", length(stations_needed))
msg("  Weather files available:", length(weather_available))
msg("  Matched:", length(matched))

if (length(unmatched_dates) > 0) {
  msg("\n  WARNING: Stations in dates but NO weather file:")
  msg("    ", paste(unmatched_dates, collapse = ", "))
}

if (length(unmatched_weather) > 0) {
  msg("\n  INFO: Weather files with no matching dates:")
  msg("    ", paste(unmatched_weather, collapse = ", "))
}

weather_cache <- list()

for (st in stations_needed) {
  filepath <- weather_lookup[station_key == st, filepath]
  if (length(filepath) == 0) {
    msg("  WARNING: No weather file for station:", st)
    next
  }

  msg("  Loading:", st)
  weather_dt <- load_weather_file(filepath[1])
  if (!is.null(weather_dt)) {
    weather_cache[[st]] <- weather_dt
  } else {
    msg("    ERROR: Failed to load")
  }
}

msg("Loaded weather for", length(weather_cache), "stations")

# -------------------- Generate Scenarios -------------------------------------
msg("\n[STEP 5] Generating scenarios...")

scenarios_list <- list()
scenario_log <- list()
scenario_counter <- 0L

n_dates <- nrow(selected_dates)
n_times <- nrow(TIME_BLOCKS)

msg("Processing", n_dates, "dates x", n_times, "times =", n_dates * n_times, "potential scenarios")

pb <- txtProgressBar(min = 0, max = n_dates, style = 3)

for (i in seq_len(n_dates)) {
  row <- selected_dates[i]
  station_key <- row$station_key
  date_i <- row$date

  # Get weather data for this station
  weather_dt <- weather_cache[[station_key]]
  if (is.null(weather_dt)) {
    for (tb_idx in seq_len(n_times)) {
      scenario_log[[length(scenario_log) + 1]] <- list(
        scenario_id = NA,
        station = station_key,
        date = as.character(date_i),
        time = TIME_BLOCKS$time_label[tb_idx],
        status = "skip",
        reason = "no_weather_data"
      )
    }
    setTxtProgressBar(pb, i)
    next
  }

  # Loop over time blocks
  for (tb_idx in seq_len(n_times)) {
    time_label <- TIME_BLOCKS$time_label[tb_idx]
    start_time <- TIME_BLOCKS$start_time[tb_idx]

    # Construct application datetime
    app_datetime <- as.POSIXct(
      paste(date_i, start_time),
      tz = "Europe/Dublin",
      format = "%Y-%m-%d %H:%M"
    )

    # Extract weather slice
    slice_result <- extract_weather_slice(weather_dt, app_datetime, MAX_GAP_HOURS)

    if (!slice_result$success) {
      scenario_log[[length(scenario_log) + 1]] <- list(
        scenario_id = NA,
        station = station_key,
        date = as.character(date_i),
        time = time_label,
        status = "skip",
        reason = slice_result$reason
      )
      next
    }

    slice_dt <- slice_result$data

    # Create scenario
    scenario_counter <- scenario_counter + 1L
    scenario_id <- sprintf("sc%06d", scenario_counter)
    slice_filename <- paste0(scenario_id, ".csv")

    # Write weather slice
    write_slice_csv(slice_dt, file.path(weather_slices_dir, slice_filename))

    # Create scenario record
    scenarios_list[[scenario_counter]] <- data.table(
      scenario_id = scenario_id,
      station = row$station,
      station_key = station_key,
      county = row$county,
      nitrate_zone = row$nitrate_zone,
      drainage_class = if ("drainage_class" %in% names(row)) row$drainage_class else NA_character_,
      year = row$year,
      period = row$period,
      date = format(date_i, "%Y-%m-%d"),
      time_of_day = time_label,
      application_time = start_time,
      application_datetime = format(app_datetime, "%Y-%m-%dT%H:%M:%S"),
      weather_slice_file = slice_filename,
      t0_air_temp = round(slice_dt[ctime == 0, air.temp], 2),
      t0_rain_rate = round(slice_dt[ctime == 0, rain.rate], 3),
      t0_wind = round(slice_dt[ctime == 0, wind.2m], 2),
      smd = if ("smd" %in% names(row)) row$smd else NA_real_,
      app_method = app_method
    )

    scenario_log[[length(scenario_log) + 1]] <- list(
      scenario_id = scenario_id,
      station = station_key,
      date = as.character(date_i),
      time = time_label,
      status = "created",
      reason = NA
    )
  }

  setTxtProgressBar(pb, i)
}

close(pb)

# -------------------- Compile and Save Outputs -------------------------------
msg("\n[STEP 6] Saving outputs...")

# Scenarios
if (length(scenarios_list) == 0) {
  stop("No scenarios created. Check scenario_log.csv for issues.")
}

scenarios_dt <- rbindlist(scenarios_list, fill = TRUE)
fwrite(scenarios_dt, file.path(output_dir, "scenarios.csv"))
msg("Saved scenarios.csv with", nrow(scenarios_dt), "scenarios")

# Scenario log
log_dt <- rbindlist(lapply(scenario_log, as.data.table), fill = TRUE)
fwrite(log_dt, file.path(output_dir, "scenario_log.csv"))
msg("Saved scenario_log.csv")

# Slurry baseline copy
slb_out <- data.table(
  slurry_id = "baseline",
  tan.app = slb$tan.app[1],
  man.dm = slb$man.dm[1],
  man.ph = slb$man.ph[1],
  app.rate = slb$app.rate[1],
  crop.z = if ("crop.z" %in% names(slb)) slb$crop.z[1] else 5,
  time.incorp = if ("time.incorp" %in% names(slb)) slb$time.incorp[1] else 0,
  app.mthd = app_method
)
fwrite(slb_out, file.path(output_dir, "slurry_baseline.csv"))
msg("Saved slurry_baseline.csv")

# -------------------- Summary ------------------------------------------------
msg("\n[STEP 7] Summary statistics...")

by_time <- scenarios_dt[, .N, by = time_of_day]
msg("\nScenarios by time of day:")
print(by_time)

by_period <- scenarios_dt[, .N, by = period]
msg("\nScenarios by period:")
print(by_period)

by_year <- scenarios_dt[, .N, by = year]
msg("\nScenarios by year:")
print(by_year[order(year)])

skip_summary <- log_dt[status == "skip", .N, by = reason]
if (nrow(skip_summary) > 0) {
  msg("\nSkipped scenarios by reason:")
  print(skip_summary[order(-N)])
}

# -------------------- Final Summary ------------------------------------------
msg("\n", "=" |> rep(70) |> paste(collapse = ""))
msg("SCENARIO GENERATION COMPLETE")
msg("=" |> rep(70) |> paste(collapse = ""))
msg("")
msg("KEY OUTPUTS:")
msg("  scenarios.csv        - Master scenario table")
msg("  weather_slices/      - 168-hour weather files (one per scenario)")
msg("  slurry_baseline.csv  - Fixed slurry properties")
msg("  scenario_log.csv     - Processing log")
msg("")
msg("SUMMARY:")
msg("  Total scenarios:", nrow(scenarios_dt))
msg("  Unique stations:", uniqueN(scenarios_dt$station))
msg("  Year range:", min(scenarios_dt$year), "-", max(scenarios_dt$year))
msg("  Application method:", app_method, "(fixed)")
msg("  Time blocks:", paste(TIME_BLOCKS$time_label, collapse = ", "))
msg("")
msg("NEXT STEP: Run 03_monte_carlo.R")
msg("=" |> rep(70) |> paste(collapse = ""))
