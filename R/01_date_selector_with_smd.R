################################################################################
# 01_date_selector_with_smd.R
#
# DESCRIPTION:
#   Selects spreading dates for ALFAM2 analysis using weather criteria AND
#   Soil Moisture Deficit (SMD) filtering. Implements the Schulte et al. (2005)
#   Hybrid SMD Model for Irish conditions.
#
# DRAINAGE GRID:
#   Uses 5km resolution grid derived from EPA/Teagasc Indicative Soil Drainage
#   Map (Creamer et al. 2016). Grid: 101 cols × 83 rows covering Ireland.
#   Accuracy: ~95% on validation locations.
#
# OUTPUTS:
#   - selected_dates_df.RData / .csv  : Main output for downstream scripts
#   - date_selection_gaps.csv          : Failed station/year/period combinations
#   - date_selection_log.csv           : Processing log per station
#   - date_selection_summary.txt       : Human-readable summary report
#
# REQUIREMENTS:
#   - Weather files with hourly: datetime, rain, temp, wind
#   - Station metadata with coordinates (latitude, longitude)
#
# VERSION: 2.1
################################################################################

# ==============================================================================
# USER SETTINGS - EDIT THIS SECTION
# ==============================================================================
# Set these paths to match your local directory structure

# --- File paths ---
folder_path           <- file.path("data", "weather")
station_metadata_xlsx <- file.path("data", "Station_metadata.xlsx")
output_dir            <- file.path("output", "01_date_selection")

# --- Date range ---
min_year <- 2013L
max_year <- 2025L

# --- Weather thresholds (standard spreading conditions) ---
min_temp_c         <- 5     # Minimum daily mean temperature (°C)
max_rain_day_mm    <- 3     # Maximum rainfall on spreading day (mm)
max_rain_72h_mm    <- 15    # Maximum cumulative rainfall over 72h (mm)

# --- SMD thresholds ---
# SMD > 0 = soil can absorb water = suitable for spreading
# SMD < 0 = waterlogged = unsuitable
smd_threshold_mm   <- 0     # Minimum SMD for spreading (mm); 0 = at field capacity
use_smd_filter     <- TRUE  # Set FALSE to disable SMD filtering (e.g., if no reliable PE data)

# --- Period selection ---
min_gap_days       <- 35    # Minimum gap between selected dates (days)

# --- Processing options ---
verbose            <- TRUE  # Print detailed progress
save_intermediates <- TRUE  # Save daily summaries per station for debugging

# ==============================================================================
# PACKAGES
# ==============================================================================

required_packages <- c("readxl", "dplyr", "lubridate", "readr", "tibble",
                       "data.table", "tools")

for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
  }
}

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(lubridate)
  library(readr)
  library(tibble)
  library(data.table)
  library(tools)
})

# ==============================================================================
# 5km DRAINAGE GRID (from EPA/Teagasc Indicative Soil Drainage Map)
# ==============================================================================
# Grid: 101 cols × 83 rows covering Ireland
# Key: W=Well Drained, M=Moderately Drained, P=Poorly Drained, X=Sea/Outside
# Source: Creamer et al. (2016), via ireland_smd_forecast_v4_2.R

GRID_LON_MIN <- -10.50
GRID_LON_MAX <- -5.50
GRID_LAT_MIN <- 51.40
GRID_LAT_MAX <- 55.50
GRID_RESOLUTION <- 0.05

make_row <- function(pattern) {
  row <- rep("X", 101)
  for (p in pattern) {
    s <- as.integer(p[1]); e <- as.integer(p[2]); ch <- as.character(p[3])
    if (s >= 1 && e <= 101 && s <= e) row[s:e] <- ch
  }
  paste(row, collapse = "")
}

generate_drainage_grid <- function() {
  rows <- vector("character", 83)

  # South (Rows 1-20): Cork & Kerry
  rows[1]  <- make_row(list(c(68,78,"P"), c(79,92,"W")))
  rows[2]  <- make_row(list(c(66,76,"P"), c(77,92,"W")))
  rows[3]  <- make_row(list(c(64,74,"P"), c(75,92,"W")))
  rows[4]  <- make_row(list(c(62,72,"P"), c(73,92,"W")))
  rows[5]  <- make_row(list(c(60,70,"P"), c(71,92,"W")))
  rows[6]  <- make_row(list(c(58,68,"P"), c(69,92,"W")))
  rows[7]  <- make_row(list(c(56,66,"P"), c(67,92,"W")))
  rows[8]  <- make_row(list(c(54,64,"P"), c(65,92,"W")))
  rows[9]  <- make_row(list(c(52,62,"P"), c(63,92,"W")))
  rows[10] <- make_row(list(c(38,40,"P"), c(41,92,"W")))
  rows[11] <- make_row(list(c(14,41,"P"), c(42,92,"W")))
  rows[12] <- make_row(list(c(6,10,"P"), c(14,42,"P"), c(43,92,"W")))
  rows[13] <- make_row(list(c(14,43,"P"), c(44,92,"W")))
  rows[14] <- make_row(list(c(14,42,"P"), c(43,50,"M"), c(51,92,"W")))
  rows[15] <- make_row(list(c(16,40,"P"), c(41,52,"M"), c(53,92,"W")))
  rows[16] <- make_row(list(c(18,38,"P"), c(39,45,"M"), c(46,92,"W")))
  rows[17] <- make_row(list(c(20,36,"P"), c(37,56,"M"), c(57,92,"W")))
  rows[18] <- make_row(list(c(22,34,"P"), c(35,58,"M"), c(59,92,"W")))
  rows[19] <- make_row(list(c(24,32,"P"), c(33,60,"M"), c(61,94,"W")))
  rows[20] <- make_row(list(c(26,30,"P"), c(31,62,"M"), c(63,94,"W")))

  # Mid-South (Rows 21-30): Clare, Limerick, Tipperary, Kilkenny
  rows[21] <- make_row(list(c(28,32,"P"), c(33,64,"M"), c(65,94,"W")))
  rows[22] <- make_row(list(c(30,34,"P"), c(35,66,"M"), c(67,94,"W")))
  rows[23] <- make_row(list(c(32,36,"P"), c(37,68,"M"), c(69,94,"W")))
  rows[24] <- make_row(list(c(28,32,"P"), c(33,70,"M"), c(71,94,"W")))
  rows[25] <- make_row(list(c(26,30,"P"), c(31,72,"M"), c(73,92,"W"), c(93,96,"M")))
  rows[26] <- make_row(list(c(24,28,"P"), c(29,40,"M"), c(41,74,"M"), c(75,90,"W"), c(91,96,"M")))
  rows[27] <- make_row(list(c(22,26,"P"), c(27,42,"M"), c(43,76,"M"), c(77,89,"W"), c(90,96,"M")))
  rows[28] <- make_row(list(c(20,24,"P"), c(25,35,"W"), c(36,78,"M"), c(79,88,"W"), c(89,94,"M"), c(95,96,"P")))
  rows[29] <- make_row(list(c(18,22,"P"), c(23,37,"W"), c(38,80,"M"), c(81,87,"W"), c(88,93,"M"), c(94,96,"P")))
  rows[30] <- make_row(list(c(16,20,"P"), c(21,39,"W"), c(40,70,"M"), c(71,86,"W"), c(87,92,"M"), c(93,96,"P")))

  # Midlands (Rows 31-42): Galway, Offaly, Dublin
  rows[31] <- make_row(list(c(14,19,"P"), c(20,41,"W"), c(42,68,"M"), c(69,85,"W"), c(86,91,"M"), c(92,96,"P")))
  rows[32] <- make_row(list(c(12,18,"P"), c(19,30,"M"), c(31,43,"M"), c(44,55,"M"), c(56,62,"P"), c(63,84,"M"), c(85,90,"M"), c(91,96,"P")))
  rows[33] <- make_row(list(c(10,17,"P"), c(18,31,"M"), c(32,45,"M"), c(46,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[34] <- make_row(list(c(8,16,"P"), c(17,32,"M"), c(33,47,"M"), c(48,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[35] <- make_row(list(c(6,15,"P"), c(16,33,"M"), c(34,49,"M"), c(50,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[36] <- make_row(list(c(6,14,"P"), c(15,34,"M"), c(35,51,"M"), c(52,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[37] <- make_row(list(c(6,13,"P"), c(14,35,"M"), c(36,53,"M"), c(54,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[38] <- make_row(list(c(6,12,"P"), c(13,30,"P"), c(31,36,"M"), c(37,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[39] <- make_row(list(c(6,11,"P"), c(12,26,"P"), c(27,37,"M"), c(38,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[40] <- make_row(list(c(6,10,"P"), c(11,25,"P"), c(26,38,"M"), c(39,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[41] <- make_row(list(c(6,9,"P"), c(10,24,"P"), c(25,39,"M"), c(40,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[42] <- make_row(list(c(6,8,"P"), c(9,23,"P"), c(24,27,"P"), c(28,40,"M"), c(41,55,"M"), c(56,62,"P"), c(63,96,"M")))

  # West (Rows 43-50): Connemara, Mayo, Roscommon
  rows[43] <- make_row(list(c(6,22,"P"), c(23,41,"M"), c(42,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[44] <- make_row(list(c(6,21,"P"), c(22,42,"M"), c(43,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[45] <- make_row(list(c(6,20,"P"), c(21,43,"M"), c(44,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[46] <- make_row(list(c(6,19,"P"), c(20,44,"M"), c(45,55,"M"), c(56,62,"P"), c(63,96,"M")))
  rows[47] <- make_row(list(c(6,18,"P"), c(19,45,"M"), c(46,52,"M"), c(53,62,"P"), c(63,96,"M")))
  rows[48] <- make_row(list(c(6,17,"P"), c(18,46,"M"), c(47,52,"M"), c(53,62,"P"), c(63,96,"M")))
  rows[49] <- make_row(list(c(6,16,"P"), c(17,96,"M")))
  rows[50] <- make_row(list(c(6,15,"P"), c(16,96,"M")))

  # Northwest (Rows 51-60): Mayo, Sligo, Leitrim
  rows[51] <- make_row(list(c(6,14,"P"), c(15,96,"M")))
  rows[52] <- make_row(list(c(6,13,"P"), c(14,96,"M")))
  rows[53] <- make_row(list(c(6,12,"P"), c(13,96,"M")))
  rows[54] <- make_row(list(c(6,11,"P"), c(12,96,"M")))
  rows[55] <- make_row(list(c(6,10,"P"), c(11,96,"M")))
  rows[56] <- make_row(list(c(6,10,"P"), c(11,96,"M")))
  rows[57] <- make_row(list(c(6,12,"P"), c(13,96,"M")))
  rows[58] <- make_row(list(c(6,13,"P"), c(14,38,"M"), c(39,52,"P"), c(53,96,"M")))
  rows[59] <- make_row(list(c(6,14,"P"), c(15,38,"M"), c(39,54,"P"), c(55,96,"M")))
  rows[60] <- make_row(list(c(6,15,"P"), c(16,38,"M"), c(39,56,"P"), c(57,96,"M")))

  # Donegal South (Rows 61-70)
  rows[61] <- make_row(list(c(6,16,"P"), c(17,38,"M"), c(39,58,"P"), c(59,96,"M")))
  rows[62] <- make_row(list(c(6,17,"P"), c(18,38,"M"), c(39,60,"P"), c(61,96,"M")))
  rows[63] <- make_row(list(c(6,18,"P"), c(19,38,"M"), c(39,62,"P"), c(63,96,"M")))
  rows[64] <- make_row(list(c(6,19,"P"), c(20,38,"M"), c(39,64,"P"), c(65,96,"M")))
  rows[65] <- make_row(list(c(6,20,"P"), c(21,38,"M"), c(39,66,"P"), c(67,96,"M")))
  rows[66] <- make_row(list(c(6,21,"P"), c(22,38,"M"), c(39,68,"P"), c(69,96,"M")))
  rows[67] <- make_row(list(c(6,22,"P"), c(23,38,"M"), c(39,70,"P"), c(71,96,"M")))
  rows[68] <- make_row(list(c(6,23,"P"), c(24,38,"M"), c(39,72,"P"), c(73,96,"M")))
  rows[69] <- make_row(list(c(6,24,"P"), c(25,38,"M"), c(39,74,"P"), c(75,96,"M")))
  rows[70] <- make_row(list(c(6,25,"P"), c(26,38,"M"), c(39,76,"P"), c(77,96,"M")))

  # Donegal North (Rows 71-83)
  rows[71] <- make_row(list(c(6,78,"P"), c(79,96,"M")))
  rows[72] <- make_row(list(c(6,80,"P"), c(81,96,"M")))
  rows[73] <- make_row(list(c(8,82,"P"), c(83,94,"M")))
  rows[74] <- make_row(list(c(10,84,"P"), c(85,92,"M")))
  rows[75] <- make_row(list(c(12,86,"P"), c(87,90,"M")))
  rows[76] <- make_row(list(c(14,88,"P")))
  rows[77] <- make_row(list(c(16,86,"P")))
  rows[78] <- make_row(list(c(18,84,"P")))
  rows[79] <- make_row(list(c(20,82,"P")))
  rows[80] <- make_row(list(c(22,80,"P")))
  rows[81] <- make_row(list(c(24,76,"P")))
  rows[82] <- make_row(list(c(26,72,"P")))
  rows[83] <- make_row(list(c(28,68,"P")))

  return(rows)
}

# Generate grid at script load time
DRAINAGE_GRID <- generate_drainage_grid()

# ==============================================================================
# DRAINAGE LOOKUP FROM 5km GRID
# ==============================================================================

get_drainage_from_grid <- function(lon, lat) {
  # Validate inputs
  if (is.na(lon) || is.na(lat)) {
    return(list(class = "Moderate", drain_rate = 2, smd_min = -10,
                confidence = "Low", source = "Missing coordinates - default"))
  }

  # Check if within Ireland grid bounds
  if (lon < GRID_LON_MIN || lon > GRID_LON_MAX ||
      lat < GRID_LAT_MIN || lat > GRID_LAT_MAX) {
    return(list(class = "Moderate", drain_rate = 2, smd_min = -10,
                confidence = "Low", source = "Outside grid bounds - default"))
  }

  # Calculate grid indices
  lon_idx <- round((lon - GRID_LON_MIN) / GRID_RESOLUTION) + 1
  lat_idx <- round((lat - GRID_LAT_MIN) / GRID_RESOLUTION) + 1
  lon_idx <- max(1, min(lon_idx, 101))
  lat_idx <- max(1, min(lat_idx, 83))

  # Look up drainage class
  ch <- substr(DRAINAGE_GRID[lat_idx], lon_idx, lon_idx)

  result <- switch(ch,
    "W" = list(class = "Well", drain_rate = 5, smd_min = 0, confidence = "High"),
    "M" = list(class = "Moderate", drain_rate = 2, smd_min = -10, confidence = "High"),
    "P" = list(class = "Poor", drain_rate = 0.5, smd_min = -10, confidence = "High"),
    list(class = "Moderate", drain_rate = 2, smd_min = -10, confidence = "Low")
  )
  result$source <- "EPA/Teagasc Grid (5km resolution)"
  return(result)
}

# ==============================================================================
# SMD MODEL FUNCTIONS (Schulte et al. 2005 Hybrid Model)
# ==============================================================================
# The SMD model tracks soil moisture using:
#   SMD_new = SMD_current + AE - Rain + Drainage
# Where AE = Actual Evapotranspiration (reduced from PE when soil is dry)
# Drainage occurs when soil is above field capacity (SMD < 0)

# --- Hargreaves PE estimation from temperature ---
# This is a temperature-based method when only temp is available
# PE = 0.0023 * Ra * sqrt(Trange) * (Tmean + 17.8)

estimate_pe_hargreaves <- function(tmean, tmin = NA, tmax = NA, doy, lat = 53.5) {
  # If only mean temp available, estimate range as ~8°C (Irish average)
  if (is.na(tmin) || is.na(tmax)) {
    trange <- 8
  } else {
    trange <- tmax - tmin
    trange <- pmax(trange, 1)  # Minimum 1°C range
  }

  # Extraterrestrial radiation (Ra) approximation for Ireland (MJ/m²/day)
  # Monthly averages at ~53.5°N latitude
  ra_monthly <- c(7.8, 12.5, 19.8, 28.5, 35.0, 37.5,
                  36.0, 31.0, 23.5, 15.5, 9.5, 6.5)

  # Convert day-of-year to approximate month (1-12)
  month_num <- pmin(pmax(ceiling(doy / 30.44), 1), 12)

  ra <- ra_monthly[month_num]

  # Hargreaves equation (returns mm/day)
  pe <- 0.0023 * ra * sqrt(trange) * (tmean + 17.8) * 0.408

  # Constrain to reasonable Irish PE range (0-6 mm/day)
  pe <- pmax(0, pmin(pe, 6))

  return(pe)
}

# --- SMD model calculation ---
# Runs the Schulte et al. hybrid model on daily data
# IMPORTANT: Handles NA values gracefully

calculate_smd_series <- function(daily_dt, drainage, initial_smd = 10) {
  # Parameters
  smd_max <- 110       # Maximum SMD (drought conditions)
  smd_critical <- 10   # Below this, AE = PE
  smd_min <- drainage$smd_min
  drain_rate <- drainage$drain_rate

  n <- nrow(daily_dt)
  smd <- numeric(n)
  current_smd <- initial_smd

  for (i in seq_len(n)) {
    rain <- daily_dt$total_rain[i]
    pe <- daily_dt$pe[i]

    # Handle NA values - assume neutral conditions if data missing
    if (is.na(rain)) rain <- 0
    if (is.na(pe)) pe <- 2  # Approximate average PE for Ireland

    # Calculate actual evapotranspiration
    if (current_smd <= smd_critical) {
      ae <- pe
    } else {
      ae <- pe * (smd_max - current_smd) / (smd_max - smd_critical)
      ae <- max(0, ae)
    }

    # Update SMD
    smd_new <- current_smd + ae - rain

    # Apply drainage if waterlogged
    if (smd_new < 0) {
      drain <- min(abs(smd_new), drain_rate)
      smd_new <- smd_new + drain
    }

    # Constrain to limits
    smd_new <- max(smd_min, min(smd_max, smd_new))
    smd[i] <- smd_new
    current_smd <- smd_new
  }

  return(smd)
}

# ==============================================================================
# SPREADING PERIODS BY NITRATE ZONE
# ==============================================================================
# These define the legal spreading windows for each zone
# Zone A = earliest start (Jan 15), Zone C = latest start (Mar 1)

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

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

msg <- function(...) {
  if (verbose) cat(format(Sys.time(), "[%H:%M:%S]"), ..., "\n")
}

# --- Normalise station names for matching ---
normalise_station_name <- function(x) {
  x <- tolower(x)
  x <- gsub("\\s+", "", x)           # Remove spaces
  x <- gsub("[_.-]", "", x)          # Remove punctuation
  x <- gsub("\\.xlsx$|\\.xls$", "", x)  # Remove extension
  x
}

# --- Get earliest date in window with minimum gap from previous ---
get_earliest_with_gap <- function(dates, start_date, end_date, prev_date = NA, min_gap = 35) {
  candidates <- dates[dates >= start_date & dates <= end_date]

  if (!is.na(prev_date)) {
    candidates <- candidates[candidates >= (prev_date + days(min_gap))]
  }

  if (length(candidates) == 0) return(NA_Date_)
  min(candidates)
}

# ==============================================================================
# MAIN PROCESSING
# ==============================================================================

msg("==================================================================")
msg("DATE SELECTOR WITH SMD FILTERING v2.1")
msg("==================================================================")

# --- Create output directory ---
if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
  msg("Created output directory:", output_dir)
}

# --- Find weather files ---
weather_files <- list.files(folder_path, pattern = "\\.(xlsx|xls)$",
                            full.names = TRUE, ignore.case = TRUE)

if (length(weather_files) == 0) {
  stop("No weather files found in: ", folder_path)
}

msg("Found", length(weather_files), "weather files")

# --- Load station metadata ---
if (!file.exists(station_metadata_xlsx)) {
  warning("Station metadata file not found. Using default Zone B and moderate drainage.")
  station_meta <- NULL
} else {
  station_meta <- as.data.table(read_excel(station_metadata_xlsx))
  setnames(station_meta, tolower(gsub("\\s+", "_", names(station_meta))))

  # Normalise column names
  if ("station_name" %in% names(station_meta)) {
    station_meta[, station_key := normalise_station_name(station_name)]
  }
  if ("nitrate_zone" %in% names(station_meta)) {
    setnames(station_meta, "nitrate_zone", "nitratezone", skip_absent = TRUE)
  }

  msg("Loaded metadata for", nrow(station_meta), "stations")

  # Show drainage classification for all stations
  if (verbose && all(c("latitude", "longitude") %in% names(station_meta))) {
    msg("\nDrainage classifications from 5km grid:")
    for (i in seq_len(nrow(station_meta))) {
      lat <- as.numeric(station_meta$latitude[i])
      lon <- as.numeric(station_meta$longitude[i])
      drainage <- get_drainage_from_grid(lon, lat)
      msg("  ", station_meta$station_name[i], ": ", drainage$class,
          " (", drainage$source, ")")
    }
    msg("")
  }
}

# --- Initialise output containers ---
all_selected     <- list()
all_gaps         <- list()
processing_log   <- list()
station_summaries <- list()

# ==============================================================================
# PROCESS EACH STATION
# ==============================================================================

for (path in weather_files) {
  st_file <- basename(path)
  st_key <- normalise_station_name(st_file)

  # --- Match to metadata ---
  if (!is.null(station_meta) && "station_key" %in% names(station_meta)) {
    meta_row <- station_meta[station_key == st_key]
    if (nrow(meta_row) == 0) {
      # Try partial match - find any metadata station that contains or is contained in the file name
      meta_row <- station_meta[sapply(station_key, function(mk) {
        grepl(st_key, mk, fixed = TRUE) | grepl(mk, st_key, fixed = TRUE)
      })]
    }
  } else {
    meta_row <- data.table()
  }

  # Get nitrate zone (default B)
  if (nrow(meta_row) > 0 && "nitratezone" %in% names(meta_row)) {
    nz <- toupper(substr(meta_row$nitratezone[1], 1, 1))
    if (!nz %in% c("A", "B", "C")) nz <- "B"
  } else {
    nz <- "B"
  }

  # Get coordinates for drainage lookup using 5km grid
  if (nrow(meta_row) > 0 && all(c("latitude", "longitude") %in% names(meta_row))) {
    lat <- as.numeric(meta_row$latitude[1])
    lon <- as.numeric(meta_row$longitude[1])
    drainage <- get_drainage_from_grid(lon, lat)
  } else {
    lat <- NA
    lon <- NA
    # Default to moderate if no coordinates - but warn
    drainage <- list(class = "Moderate", drain_rate = 2, smd_min = -10,
                     confidence = "Low", source = "No coordinates in metadata")
    warning("No coordinates for station ", st_file, " - using default moderate drainage")
  }

  msg("\n[", which(weather_files == path), "/", length(weather_files), "] Processing:",
      st_file, "(Zone", nz, ", Drainage:", drainage$class, ")")

  # --- Read weather file ---
  df_raw <- tryCatch({
    read_excel(path, col_names = TRUE)
  }, error = function(e) {
    msg("  ERROR reading file:", e$message)
    return(NULL)
  })

  if (is.null(df_raw)) {
    processing_log[[st_file]] <- list(
      station = st_file, status = "failed_read", dates_found = 0,
      reason = "Could not read Excel file"
    )
    next
  }

  # --- Standardise column names ---
  # Show original column names for debugging
  if (verbose) {
    msg("  Original columns:", paste(names(df_raw)[1:min(6, ncol(df_raw))], collapse = ", "))
  }

  if (ncol(df_raw) >= 4) {
    names(df_raw)[1:4] <- c("datetime", "rain", "temp", "wind")
  } else {
    msg("  ERROR: File has fewer than 4 columns")
    processing_log[[st_file]] <- list(
      station = st_file, status = "insufficient_columns", dates_found = 0,
      reason = paste("Only", ncol(df_raw), "columns found")
    )
    next
  }

  # --- Parse datetime ---
  df <- as.data.table(df_raw)

  # Check column type and parse accordingly
  # Excel numeric dates: days since 1899-12-30
  # POSIXct: already datetime
  # Character: needs parsing

  if (is.numeric(df$datetime)) {
    # Excel serial date format
    df[, datetime := as_datetime(as.numeric(datetime) * 86400, origin = "1899-12-30", tz = "UTC")]
  } else if (inherits(df$datetime, "POSIXct") || inherits(df$datetime, "POSIXlt")) {
    # Already datetime - just ensure UTC
    df[, datetime := as_datetime(datetime, tz = "UTC")]
  } else {
    # Character - try multiple formats
    df[, datetime := parse_date_time(as.character(datetime),
                                     orders = c("Ymd HMS", "Ymd HM", "Y-m-d H:M:S", "Y-m-d H:M",
                                                "d/m/Y H:M:S", "d/m/Y H:M", "m/d/Y H:M:S", "m/d/Y H:M",
                                                "dmy HMS", "dmy HM"),
                                     tz = "UTC",
                                     quiet = TRUE)]
  }

  # Check for parsing failures
  n_na <- sum(is.na(df$datetime))
  if (n_na > 0) {
    msg("  WARNING:", n_na, "datetime values failed to parse")
    # Show sample of failed rows for debugging
    if (verbose && n_na < nrow(df)) {
      failed_sample <- head(df_raw$datetime[is.na(df$datetime)], 5)
      msg("  Sample failed values:", paste(failed_sample, collapse = ", "))
    }
  }

  # Remove rows with NA datetime
  df <- df[!is.na(datetime)]

  df[, date := as_date(datetime)]

  # --- Filter to date range ---
  min_date <- as.Date(paste0(min_year, "-01-01"))
  max_date <- as.Date(paste0(max_year, "-12-31"))
  df <- df[date >= min_date & date <= max_date]

  if (nrow(df) == 0) {
    msg("  No data in date range", min_year, "-", max_year)
    processing_log[[st_file]] <- list(
      station = st_file, status = "no_data_in_range", dates_found = 0,
      reason = paste("No data between", min_year, "and", max_year)
    )
    next
  }

  msg("  Data points in range:", format(nrow(df), big.mark = ","))

  # --- Convert weather columns to numeric ---
  df[, rain := as.numeric(gsub("[^0-9.-]", "", as.character(rain)))]
  df[, temp := as.numeric(gsub("[^0-9.-]", "", as.character(temp)))]
  df[, wind := as.numeric(gsub("[^0-9.-]", "", as.character(wind)))]

  # --- Daily summary ---
  daily <- df[, .(
    mean_temp  = mean(temp, na.rm = TRUE),
    min_temp   = min(temp, na.rm = TRUE),
    max_temp   = max(temp, na.rm = TRUE),
    total_rain = sum(rain, na.rm = TRUE),
    mean_wind  = mean(wind, na.rm = TRUE),
    n_hours    = .N
  ), by = date]

  setorder(daily, date)
  daily[, year := year(date)]
  daily[, doy := yday(date)]

  # Replace infinite values with NA (can happen if all values in a day are NA)
  daily[is.infinite(mean_temp), mean_temp := NA_real_]
  daily[is.infinite(min_temp), min_temp := NA_real_]
  daily[is.infinite(max_temp), max_temp := NA_real_]
  daily[is.nan(mean_temp), mean_temp := NA_real_]
  daily[is.nan(total_rain), total_rain := 0]

  # --- Calculate PE (Hargreaves method) ---
  daily[, pe := mapply(estimate_pe_hargreaves,
                       tmean = mean_temp,
                       tmin = min_temp,
                       tmax = max_temp,
                       doy = doy)]

  # --- Calculate 72h forward rainfall ---
  daily[, rain_next72 := total_rain +
          shift(total_rain, n = 1, type = "lead", fill = 0) +
          shift(total_rain, n = 2, type = "lead", fill = 0)]

  # --- Calculate SMD series ---
  if (use_smd_filter) {
    daily[, smd := calculate_smd_series(.SD, drainage, initial_smd = 10)]
    msg("  SMD range:", round(min(daily$smd, na.rm = TRUE), 1), "to",
        round(max(daily$smd, na.rm = TRUE), 1), "mm")
  } else {
    daily[, smd := 10]  # Dummy value (always passes threshold)
  }

  # --- Define spreading window (Jan 12 - Oct 15) ---
  daily[, in_window := between(date,
                               as_date(paste0(year, "-01-12")),
                               as_date(paste0(year, "-10-15")))]

  # --- Apply all filters (with NA handling) ---
  daily[, passes_temp := !is.na(mean_temp) & mean_temp >= min_temp_c]
  daily[, passes_rain_day := !is.na(total_rain) & total_rain <= max_rain_day_mm]
  daily[, passes_rain_72h := !is.na(rain_next72) & rain_next72 <= max_rain_72h_mm]
  daily[, passes_smd := !is.na(smd) & smd >= smd_threshold_mm]

  daily[, valid_spreading := in_window & passes_temp & passes_rain_day &
          passes_rain_72h & passes_smd]

  valid_dates <- daily[valid_spreading == TRUE, date]

  msg("  Valid spreading days:", length(valid_dates), "/", nrow(daily[in_window == TRUE]))

  # Breakdown of failures
  if (verbose) {
    in_win <- daily[in_window == TRUE]
    msg("    Fails temp:", sum(!in_win$passes_temp),
        "| rain day:", sum(!in_win$passes_rain_day),
        "| rain 72h:", sum(!in_win$passes_rain_72h),
        "| SMD:", sum(!in_win$passes_smd))
  }

  # --- Save daily summary if requested ---
  if (save_intermediates) {
    summary_file <- file.path(output_dir, paste0("daily_summary_",
                                                  file_path_sans_ext(st_file), ".csv"))
    fwrite(daily, summary_file)
    station_summaries[[st_file]] <- summary_file
  }

  if (length(valid_dates) == 0) {
    msg("  No valid spreading days found")
    processing_log[[st_file]] <- list(
      station = st_file, status = "no_valid_days", dates_found = 0,
      reason = "No days passed all criteria"
    )

    # Log all periods as gaps
    sp <- spreading_periods[[nz]]
    for (yr in min_year:max_year) {
      for (i in seq_len(nrow(sp))) {
        all_gaps[[paste0(st_file, "_", yr, "_", sp$period[i])]] <- data.table(
          station = st_file,
          year = yr,
          period = sp$period[i],
          nitrate_zone = nz,
          reason = "no_valid_days_in_year",
          candidates_in_window = 0
        )
      }
    }
    next
  }

  # --- Select key dates for each period ---
  sp <- spreading_periods[[nz]]
  yrs <- min_year:max_year
  yrs <- yrs[yrs %in% unique(daily$year)]

  n_dates_selected <- 0

  for (yr in yrs) {
    dy <- valid_dates[year(valid_dates) == yr]
    prev_date <- NA

    for (i in seq_len(nrow(sp))) {
      period_name <- sp$period[i]
      sd <- as_date(paste0(yr, "-", sp$start_md[i]))
      ed <- as_date(paste0(yr, "-", sp$end_md[i]))

      # Count candidates in this window
      candidates_in_window <- sum(dy >= sd & dy <= ed)

      # Get earliest valid date with gap constraint
      edate <- get_earliest_with_gap(dy, sd, ed, prev_date, min_gap = min_gap_days)

      if (!is.na(edate)) {
        all_selected[[paste0(st_file, "_", yr, "_", period_name)]] <- data.table(
          station = st_file,
          year = yr,
          period = period_name,
          date = edate,
          nitrate_zone = nz,
          drainage_class = drainage$class
        )
        prev_date <- edate
        n_dates_selected <- n_dates_selected + 1
      } else {
        # --- Log the gap ---
        # Determine why no date was found
        if (candidates_in_window == 0) {
          reason <- "no_valid_days_in_period"
        } else if (!is.na(prev_date) && all(dy[dy >= sd & dy <= ed] < prev_date + days(min_gap_days))) {
          reason <- "gap_constraint_not_met"
        } else {
          reason <- "unknown"
        }

        all_gaps[[paste0(st_file, "_", yr, "_", period_name)]] <- data.table(
          station = st_file,
          year = yr,
          period = period_name,
          nitrate_zone = nz,
          window_start = sd,
          window_end = ed,
          prev_date = as.character(prev_date),
          reason = reason,
          candidates_in_window = candidates_in_window
        )
      }
    }
  }

  msg("  Dates selected:", n_dates_selected)
  processing_log[[st_file]] <- list(
    station = st_file,
    status = "success",
    dates_found = n_dates_selected,
    reason = "",
    drainage_class = drainage$class,
    drainage_source = drainage$source
  )
}

# ==============================================================================
# COMBINE AND EXPORT RESULTS
# ==============================================================================

msg("\n==================================================================")
msg("COMBINING RESULTS")
msg("==================================================================")

# --- Main selected dates ---
if (length(all_selected) == 0) {
  stop("\nERROR: No dates selected for any station.\n",
       "Check weather thresholds or SMD filtering.\n")
}

selected_dates_df <- rbindlist(all_selected)

# Ensure correct types
selected_dates_df[, date := as.Date(date)]
setorder(selected_dates_df, station, date)

msg("Total dates selected:", nrow(selected_dates_df))
msg("Stations with data:", uniqueN(selected_dates_df$station))
msg("Year range:", min(selected_dates_df$year), "-", max(selected_dates_df$year))

# --- Gaps ---
if (length(all_gaps) > 0) {
  gaps_df <- rbindlist(all_gaps, fill = TRUE)
  n_gaps <- nrow(gaps_df)
  msg("Gaps identified:", n_gaps)
} else {
  gaps_df <- data.table()
  n_gaps <- 0
  msg("No gaps - all periods filled!")
}

# --- Processing log ---
log_df <- rbindlist(lapply(processing_log, as.data.table), fill = TRUE)

# ==============================================================================
# SUMMARY STATISTICS
# ==============================================================================

msg("\n========== DATE SELECTION SUMMARY ==========")

cat("\nBreakdown by year:\n")
print(table(selected_dates_df$year))

cat("\nBreakdown by period:\n")
print(table(selected_dates_df$period))

cat("\nDates per station:\n")
print(selected_dates_df[, .N, by = station][order(-N)])

cat("\nDrainage class distribution:\n")
print(table(selected_dates_df$drainage_class))

if (n_gaps > 0) {
  cat("\nGap summary by reason:\n")
  print(table(gaps_df$reason))

  cat("\nGaps by period:\n")
  print(table(gaps_df$period))
}

# ==============================================================================
# SAVE OUTPUTS
# ==============================================================================

msg("\n========== SAVING OUTPUTS ==========")

# --- Main output (RData) ---
output_rdata <- file.path(output_dir, "selected_dates_df.RData")
save(selected_dates_df, file = output_rdata)
msg("Saved:", output_rdata)

# --- Main output (CSV) ---
output_csv <- file.path(output_dir, "selected_dates_df.csv")
fwrite(selected_dates_df, output_csv)
msg("Saved:", output_csv)

# --- Gaps file ---
gaps_csv <- file.path(output_dir, "date_selection_gaps.csv")
fwrite(gaps_df, gaps_csv)
msg("Saved:", gaps_csv, "(", n_gaps, "gaps)")

# --- Processing log ---
log_csv <- file.path(output_dir, "date_selection_log.csv")
fwrite(log_df, log_csv)
msg("Saved:", log_csv)

# --- Summary report ---
summary_txt <- file.path(output_dir, "date_selection_summary.txt")
sink(summary_txt)
cat("DATE SELECTION SUMMARY REPORT\n")
cat("Generated:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("================================================================\n\n")
cat("PARAMETERS:\n")
cat("  Date range:", min_year, "-", max_year, "\n")
cat("  Min temperature:", min_temp_c, "°C\n")
cat("  Max rain on day:", max_rain_day_mm, "mm\n")
cat("  Max rain 72h:", max_rain_72h_mm, "mm\n")
cat("  SMD threshold:", smd_threshold_mm, "mm (filter enabled:", use_smd_filter, ")\n")
cat("  Min gap between dates:", min_gap_days, "days\n")
cat("\nDRAINAGE GRID:\n")
cat("  Source: EPA/Teagasc Indicative Soil Drainage Map (5km resolution)\n")
cat("  Reference: Creamer et al. (2016)\n")
cat("\nRESULTS:\n")
cat("  Total dates selected:", nrow(selected_dates_df), "\n")
cat("  Stations processed:", length(weather_files), "\n")
cat("  Stations with dates:", uniqueN(selected_dates_df$station), "\n")
cat("  Gaps (missing dates):", n_gaps, "\n")
cat("\nDRAINAGE CLASS DISTRIBUTION:\n")
print(table(selected_dates_df$drainage_class))
cat("\nBREAKDOWN BY YEAR:\n")
print(table(selected_dates_df$year))
cat("\nBREAKDOWN BY PERIOD:\n")
print(table(selected_dates_df$period))
if (n_gaps > 0) {
  cat("\nGAP REASONS:\n")
  print(table(gaps_df$reason))
}
sink()
msg("Saved:", summary_txt)

# ==============================================================================
# COMPLETION
# ==============================================================================

msg("\n========== COMPLETE ==========")
msg("Selected dates:", nrow(selected_dates_df))
msg("Gaps for recovery:", n_gaps)
msg("")
msg("Next steps:")
msg("  1. Review date_selection_gaps.csv to understand missing dates")
msg("  2. Run 01b_date_gap_analysis_and_recovery.R to fill gaps if needed")
msg("  3. Run scenario generator with selected_dates_df.RData")
msg("==============================")
