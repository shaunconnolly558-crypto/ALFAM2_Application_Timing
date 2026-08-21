################################################################################
# 03_monte_carlo.R
#
# PURPOSE: Run Monte Carlo simulation with ALFAM2 parameter uncertainty
#          Captures variability from:
#          1. ALFAM2 model parameters (bootstrap sets)
#          2. Slurry properties (sampled from distributions)
#          3. Weather conditions (actual observed, via scenarios)
#
# INPUT:  scenarios.csv + weather_slices/ (from 02_scenario_generator.R)
# OUTPUT: mc_results_master.csv + summary statistics + plots
################################################################################

# ========================== LOAD PACKAGES ====================================
cat("Loading packages...\n")

required_packages <- c("data.table", "ALFAM2", "truncnorm", "future",
                       "future.apply", "ggplot2", "parallel")

for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    cat(sprintf("  Installing %s...\n", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
  }
}

suppressPackageStartupMessages({
  library(data.table)
  library(ALFAM2)
  library(truncnorm)
  library(future)
  library(future.apply)
  library(ggplot2)
  library(parallel)
})

cat("All packages loaded.\n\n")

# ========================== USER CONFIGURATION ===============================
# MODIFY THESE SETTINGS FOR YOUR SYSTEM

# ----- Input/Output Paths -----
scenarios_dir   <- file.path("output", "02_scenario_generation")
output_dir      <- file.path("output", "03_monte_carlo_results")

# Input files (from scenario generator)
scenarios_csv   <- file.path(scenarios_dir, "scenarios.csv")
weather_dir     <- file.path(scenarios_dir, "weather_slices")

# ----- RUN MODE -----
# Options: "TEST", "QUICK", "STANDARD", "COMPREHENSIVE"
#
# TEST:          20 scenarios, 10 param sets, 10 MC draws = 2,000 runs (~2 min)
# QUICK:         All scenarios, 30 param sets, 30 MC draws = ~1.7M runs (~1-2 hrs)
# STANDARD:      All scenarios, 50 param sets, 50 MC draws = ~4.7M runs (~3-5 hrs)
# COMPREHENSIVE: All scenarios, 101 param sets, 50 MC draws = ~9.5M runs (~6-12 hrs)

RUN_MODE <- "COMPREHENSIVE"  # Start with TEST to verify pipeline works!

# ----- Parallel Processing -----
# Set to number of physical cores minus 1 (leave one for system)
n_cores <- max(1, detectCores(logical = FALSE) - 1)

# ----- Random Seed -----
seed_base <- 12345

# ========================== RUN MODE PRESETS =================================

run_modes <- list(
  TEST = list(
    max_scenarios = 20,
    n_param_sets = 10,
    n_mc_draws = 10,
    description = "Quick test run to verify pipeline"
  ),
  QUICK = list(
    max_scenarios = Inf,
    n_param_sets = 30,
    n_mc_draws = 30,
    description = "Fast full run with good statistical power"
  ),
  STANDARD = list(
    max_scenarios = Inf,
    n_param_sets = 50,
    n_mc_draws = 50,
    description = "Balanced run for robust results"
  ),
  COMPREHENSIVE = list(
    max_scenarios = Inf,
    n_param_sets = 101,  # All bootstrap sets + central
    n_mc_draws = 50,
    description = "Full uncertainty quantification for publication"
  )
)

# Get settings for selected mode
if (!RUN_MODE %in% names(run_modes)) {
  stop("Invalid RUN_MODE. Choose from: ", paste(names(run_modes), collapse = ", "))
}

mode_settings <- run_modes[[RUN_MODE]]

# ========================== SLURRY DISTRIBUTIONS =============================
# Irish literature values with beta distribution for application rate
# These capture realistic variability in slurry properties

SLURRY_DISTRIBUTIONS <- list(
  man.tan = list(
    dist = "truncnorm",
    mean = 1.32,      # kg TAN per tonne slurry (Irish literature mean)
    sd = 0.51,
    min = 0.46,
    max = 2.24
  ),
  man.dm = list(
    dist = "truncnorm",
    mean = 6.4,       # % dry matter
    sd = 1.2,
    min = 3.0,
    max = 10.7
  ),
  man.ph = list(
    dist = "truncnorm",
    mean = 7.3,
    sd = 0.22,
    min = 6.8,
    max = 8.0
  ),
  app.rate = list(
    dist = "beta",
    min = 25,         # m³/ha
    max = 43,         # m³/ha
    alpha = 3.0,      # Shape parameters give:
    beta = 2.5        # Mean ~34.8, 68% above 33 m³/ha
  )
)

# Fixed parameters (not varied in Monte Carlo)
FIXED_SLURRY <- list(
  crop.z = 10,        # Grass height (cm)
  time.incorp = 0     # No incorporation (surface application)
)

# ========================== HELPER FUNCTIONS =================================

msg <- function(...) {
  cat("[", format(Sys.time(), "%H:%M:%S"), "]", ..., "\n")
}

#' Sample from truncated normal distribution
sample_truncnorm <- function(n, mean, sd, min, max) {
  truncnorm::rtruncnorm(n, a = min, b = max, mean = mean, sd = sd)
}

#' Sample from beta distribution scaled to [min, max]
sample_beta_scaled <- function(n, min, max, alpha, beta) {
  min + (max - min) * rbeta(n, shape1 = alpha, shape2 = beta)
}

#' Sample all slurry parameters for one Monte Carlo draw
#' @return Named list with all ALFAM2 slurry inputs
sample_slurry_params <- function(distributions = SLURRY_DISTRIBUTIONS,
                                 fixed = FIXED_SLURRY) {
  params <- list()

  for (name in names(distributions)) {
    d <- distributions[[name]]

    if (d$dist == "truncnorm") {
      params[[name]] <- sample_truncnorm(1, d$mean, d$sd, d$min, d$max)
    } else if (d$dist == "beta") {
      params[[name]] <- sample_beta_scaled(1, d$min, d$max, d$alpha, d$beta)
    }
  }

  # Add fixed parameters
  for (name in names(fixed)) {
    params[[name]] <- fixed[[name]]
  }

  # Derive TAN.app from man.tan and app.rate (physical consistency)
  # man.tan is kg TAN per tonne slurry
  # app.rate is m³/ha (≈ tonnes/ha for slurry density ~1)
  # TAN.app is kg TAN per ha
  params$TAN.app <- params$man.tan * params$app.rate

  return(params)
}

#' Load and validate weather slice
#' @return data.table or NULL if invalid
load_weather_slice <- function(filepath) {
  if (!file.exists(filepath)) return(NULL)

  dt <- tryCatch(fread(filepath, showProgress = FALSE), error = function(e) NULL)
  if (is.null(dt)) return(NULL)

  # Check required columns
  required <- c("ctime", "air.temp", "rain.rate", "wind.2m")
  if (!all(required %in% names(dt))) return(NULL)

  # Check 168 rows

  if (nrow(dt) != 168) return(NULL)

  return(dt)
}

#' Run single ALFAM2 simulation
#' @param weather_dt Weather data (168 rows)
#' @param slurry_params Sampled slurry parameters
#' @param alfam2_pars ALFAM2 parameter set
#' @param app_method Application method code
#' @return List with emission results or NULL if failed
run_alfam2_single <- function(weather_dt, slurry_params, alfam2_pars, app_method = "ts") {

  # Build ALFAM2 input data frame
  dat <- data.frame(
    ctime = weather_dt$ctime,
    air.temp = weather_dt$air.temp,
    rain.rate = weather_dt$rain.rate,
    wind.2m = weather_dt$wind.2m,
    TAN.app = slurry_params$TAN.app,
    man.tan = slurry_params$man.tan,
    man.dm = slurry_params$man.dm,
    man.ph = slurry_params$man.ph,
    app.rate = slurry_params$app.rate,
    crop.z = slurry_params$crop.z,
    time.incorp = slurry_params$time.incorp,
    app.mthd = app_method,
    stringsAsFactors = FALSE
  )

  # Run ALFAM2
  result <- tryCatch({
    res <- suppressWarnings({
      ALFAM2::alfam2(dat = dat,
                    pars = alfam2_pars,
                    app.name = "TAN.app",
                    time.name = "ctime",
                    check = FALSE)
    })

    # Extract results
    e_profile <- as.numeric(res$e)
    e_final <- tail(e_profile, 1)  # Final cumulative emission (% of TAN)
    emission_kg_ha <- (e_final / 100) * slurry_params$TAN.app

    list(
      success = TRUE,
      emission_frac = e_final,           # % of applied TAN
      emission_kg_ha = emission_kg_ha,   # kg NH3-N per ha
      TAN_applied = slurry_params$TAN.app
    )
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })

  return(result)
}

#' Check available disk space (GB)
check_disk_space <- function(path) {
  tryCatch({
    if (.Platform$OS.type == "windows") {
      drive <- substr(normalizePath(path), 1, 2)
      cmd <- sprintf('powershell "(Get-WmiObject Win32_LogicalDisk -Filter \\"DeviceID=\'%s\'\\" ).FreeSpace"', drive)
      result <- system(cmd, intern = TRUE, show.output.on.console = FALSE)
      if (length(result) > 0 && !is.na(as.numeric(result[1]))) {
        return(as.numeric(result[1]) / (1024^3))
      }
    }
    return(NA)
  }, error = function(e) NA)
}

# ========================== MAIN EXECUTION ===================================

msg("=" |> rep(70) |> paste(collapse = ""))
msg("ALFAM2 MONTE CARLO SIMULATION")
msg("=" |> rep(70) |> paste(collapse = ""))
msg("")
msg("Run Mode:", RUN_MODE)
msg("Description:", mode_settings$description)
msg("")

# Create output directory
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
msg("Output directory:", output_dir)

# Check disk space
free_gb <- check_disk_space(output_dir)
if (!is.na(free_gb)) {
  msg("Available disk space:", round(free_gb, 1), "GB")
  if (free_gb < 5) {
    warning("Low disk space! Results may not save properly.")
  }
}

# -------------------- Load Scenarios ----------------------------------------
msg("\n[STEP 1] Loading scenarios...")

if (!file.exists(scenarios_csv)) {
  stop("Scenarios file not found: ", scenarios_csv)
}

scenarios <- fread(scenarios_csv)
msg("Total scenarios available:", nrow(scenarios))

# Apply scenario limit for test mode
if (is.finite(mode_settings$max_scenarios) && nrow(scenarios) > mode_settings$max_scenarios) {
  set.seed(seed_base)
  scenarios <- scenarios[sample(.N, mode_settings$max_scenarios)]
  msg("Limited to", nrow(scenarios), "scenarios for", RUN_MODE, "mode")
}

# Check weather files exist
scenarios[, weather_path := file.path(weather_dir, weather_slice_file)]
scenarios[, weather_exists := file.exists(weather_path)]
n_missing <- sum(!scenarios$weather_exists)
if (n_missing > 0) {
  msg("WARNING:", n_missing, "scenarios missing weather files - will be skipped")
  scenarios <- scenarios[weather_exists == TRUE]
}

msg("Scenarios to process:", nrow(scenarios))

# -------------------- Load ALFAM2 Parameter Sets ----------------------------
msg("\n[STEP 2] Loading ALFAM2 parameter sets...")

# Central parameters (named numeric vector)
central_pars <- ALFAM2::alfam2pars03
msg("Loaded central parameter set")
msg("  Class:", class(central_pars)[1])
msg("  Length:", length(central_pars), "parameters")

# Bootstrap parameter sets for uncertainty
# NOTE: alfam2pars03var is a MATRIX or DATA FRAME (rows = parameter sets, cols = parameters)
# NOT a list! We need to extract rows and convert to named vectors.

bootstrap_pars_list <- list()  # Will store as list of named vectors
n_available <- 0

if (exists("alfam2pars03var", where = "package:ALFAM2")) {
  bootstrap_raw <- ALFAM2::alfam2pars03var

  msg("Found bootstrap parameters:")
  msg("  Class:", class(bootstrap_raw)[1])

  if (is.matrix(bootstrap_raw) || is.data.frame(bootstrap_raw)) {
    # It's a matrix/data.frame - rows are parameter sets
    n_available <- nrow(bootstrap_raw)
    msg("  Dimensions:", nrow(bootstrap_raw), "sets x", ncol(bootstrap_raw), "parameters")

    # Convert each row to a named numeric vector (same format as central_pars)
    for (i in seq_len(n_available)) {
      row_vec <- as.numeric(bootstrap_raw[i, ])
      names(row_vec) <- colnames(bootstrap_raw)
      bootstrap_pars_list[[i]] <- row_vec
    }
    msg("  Converted", n_available, "bootstrap sets to named vectors")

  } else if (is.list(bootstrap_raw)) {
    # It's already a list
    bootstrap_pars_list <- bootstrap_raw
    n_available <- length(bootstrap_raw)
    msg("  Already a list with", n_available, "sets")

  } else {
    warning("Unexpected bootstrap parameter format: ", class(bootstrap_raw)[1])
    n_available <- 0
  }
} else {
  warning("Bootstrap parameter sets (alfam2pars03var) not found - using central parameters only")
}

msg("Total bootstrap sets available:", n_available)

# Select parameter sets based on run mode
n_param_sets <- min(mode_settings$n_param_sets, n_available + 1)

if (n_param_sets <= 1 || n_available == 0) {
  # Central only
  param_sets <- list(central_pars)
  param_set_ids <- "ps000_central"
  msg("Using central parameter set only")
} else {
  # Central + subset of bootstrap
  n_bootstrap <- n_param_sets - 1

  if (n_bootstrap < n_available) {
    set.seed(seed_base + 1)
    selected_idx <- sort(sample(n_available, n_bootstrap))
    bootstrap_subset <- bootstrap_pars_list[selected_idx]
    msg("Selected", n_bootstrap, "of", n_available, "bootstrap sets (random sample)")
  } else {
    bootstrap_subset <- bootstrap_pars_list
    msg("Using all", n_available, "bootstrap sets")
  }

  param_sets <- c(list(central_pars), bootstrap_subset)
  param_set_ids <- c("ps000_central", sprintf("ps%03d", seq_along(bootstrap_subset)))
}

msg("Using", length(param_sets), "parameter sets total")

# Verify parameter sets are valid
msg("\nParameter set verification:")
for (i in seq_along(param_sets)) {
  ps <- param_sets[[i]]
  ps_id <- param_set_ids[i]
  is_valid <- is.numeric(ps) && length(ps) > 0 && !is.null(names(ps))
  if (!is_valid) {
    msg("  WARNING:", ps_id, "- INVALID (class:", class(ps)[1], ", length:", length(ps), ")")
  } else if (i <= 3 || i == length(param_sets)) {
    # Show first 3 and last for verification
    msg("  ", ps_id, "- OK (", length(ps), "params, first 3:",
        paste(head(names(ps), 3), collapse=", "), ")")
  }
}
if (length(param_sets) > 4) {
  msg("  ... (", length(param_sets) - 4, "more sets verified)")
}

# -------------------- CRITICAL: Test Parameter Sets with ALFAM2 --------------
msg("\n[STEP 2b] Testing parameter sets with ALFAM2...")

# Create minimal test data
test_dat <- data.frame(
  ctime = 0:5,  # 6 hours
  air.temp = rep(15, 6),
  rain.rate = rep(0, 6),
  wind.2m = rep(2, 6),
  TAN.app = rep(45, 6),
  man.tan = rep(1.32, 6),
  man.dm = rep(6.4, 6),
  man.ph = rep(7.3, 6),
  app.rate = rep(34, 6),
  crop.z = rep(10, 6),
  time.incorp = rep(0, 6),
  app.mthd = rep("ts", 6),
  stringsAsFactors = FALSE
)

# Test each parameter set
valid_param_sets <- list()
valid_param_set_ids <- character()
failed_count <- 0

for (i in seq_along(param_sets)) {
  ps <- param_sets[[i]]
  ps_id <- param_set_ids[i]

  test_result <- tryCatch({
    res <- suppressWarnings({
      ALFAM2::alfam2(dat = test_dat, pars = ps,
                    app.name = "TAN.app", time.name = "ctime", check = FALSE)
    })
    e_final <- tail(res$e, 1)
    list(success = TRUE, emission = e_final)
  }, error = function(e) {
    list(success = FALSE, error = e$message)
  })

  if (test_result$success && !is.na(test_result$emission) && test_result$emission > 0) {
    valid_param_sets[[length(valid_param_sets) + 1]] <- ps
    valid_param_set_ids <- c(valid_param_set_ids, ps_id)

    if (i <= 3 || i == length(param_sets)) {
      msg("  ", ps_id, "- PASS (test emission:", round(test_result$emission, 2), "%)")
    }
  } else {
    failed_count <- failed_count + 1
    if (failed_count <= 5) {
      err_msg <- if (!test_result$success) test_result$error else "NA or zero emission"
      msg("  ", ps_id, "- FAIL:", err_msg)
    }
  }
}

if (failed_count > 5) {
  msg("  ... and", failed_count - 5, "more failures")
}

# Replace with only valid parameter sets
if (length(valid_param_sets) == 0) {
  stop("FATAL: No parameter sets passed validation! Check ALFAM2 installation.")
}

if (length(valid_param_sets) < length(param_sets)) {
  msg("\nWARNING:", length(param_sets) - length(valid_param_sets),
      "parameter sets failed validation and will be excluded")
  param_sets <- valid_param_sets
  param_set_ids <- valid_param_set_ids
}

msg("\nValidated parameter sets:", length(param_sets), "of",
    length(param_sets) + failed_count, "total")

# -------------------- Calculate Expected Work -------------------------------
n_scenarios <- nrow(scenarios)
n_mc_draws <- mode_settings$n_mc_draws
total_runs <- n_scenarios * length(param_sets) * n_mc_draws

msg("\n[STEP 3] Simulation plan:")
msg("  Scenarios:", n_scenarios)
msg("  Parameter sets:", length(param_sets))
msg("  MC draws per param set:", n_mc_draws)
msg("  Total ALFAM2 runs:", format(total_runs, big.mark = ","))

# Estimate time
est_seconds <- total_runs * 0.005  # ~5ms per run with parallel
est_minutes <- est_seconds / 60
if (est_minutes < 60) {
  msg("  Estimated time:", round(est_minutes, 1), "minutes")
} else {
  msg("  Estimated time:", round(est_minutes / 60, 1), "hours")
}

# -------------------- Setup Parallel Processing -----------------------------
msg("\n[STEP 4] Setting up parallel processing...")
msg("Physical cores available:", detectCores(logical = FALSE))
msg("Using", n_cores, "parallel workers")

# Calculate RAM allocation
# With 64 GB total, allocate ~4 GB per worker (leaving headroom for system)
ram_per_worker_gb <- 4
total_ram_allocated <- n_cores * ram_per_worker_gb
msg("RAM allocation:", ram_per_worker_gb, "GB per worker (", total_ram_allocated, "GB total)")

plan(multisession, workers = n_cores)
options(future.globals.maxSize = ram_per_worker_gb * 1024^3)  # GB per worker

# -------------------- Run Monte Carlo Simulation ----------------------------
msg("\n[STEP 5] Running Monte Carlo simulation...")

# Output files
master_csv <- file.path(output_dir, "mc_results_master.csv")
log_csv <- file.path(output_dir, "mc_run_log.csv")

# Initialize master results file with header
header_dt <- data.table(
  scenario_id = character(),
  param_set_id = character(),
  mc_draw = integer(),
  station = character(),
  year = integer(),
  date = character(),
  time_of_day = character(),
  period = character(),
  method = character(),
  temp_t0 = numeric(),
  wind_t0 = numeric(),
  man_tan = numeric(),
  man_dm = numeric(),
  man_ph = numeric(),
  app_rate = numeric(),
  TAN_applied = numeric(),
  emission_frac = numeric(),
  emission_kg_ha = numeric()
)
fwrite(header_dt, master_csv)

# Progress tracking
start_time <- Sys.time()

# ============================================================================
# OPTIMIZED PARALLEL PROCESSING
# Strategy: Parallelize at SCENARIO level (not MC draw level)
# This reduces overhead and better utilizes all cores
# ============================================================================

# Pre-load all weather data into memory (faster than loading per-scenario)
msg("Pre-loading weather data into memory...")
weather_cache <- list()
for (i in seq_len(nrow(scenarios))) {
  sc_id <- scenarios$scenario_id[i]
  weather_dt <- load_weather_slice(scenarios$weather_path[i])
  if (!is.null(weather_dt)) {
    weather_cache[[sc_id]] <- weather_dt
  }
}
msg("Loaded", length(weather_cache), "weather slices into memory")

# Create all scenario × param_set combinations to process
work_items <- CJ(
  sc_idx = seq_len(nrow(scenarios)),
  ps_idx = seq_along(param_sets)
)
work_items[, work_id := .I]

# Filter to only scenarios with weather data
scenarios[, has_weather := scenario_id %in% names(weather_cache)]
valid_sc_idx <- which(scenarios$has_weather)
work_items <- work_items[sc_idx %in% valid_sc_idx]

total_work_items <- nrow(work_items)
msg("Processing", total_work_items, "scenario × param_set combinations")
msg("Each with", n_mc_draws, "MC draws =", format(total_work_items * n_mc_draws, big.mark = ","), "total runs")

# Define worker function for one scenario × param_set combination
process_work_item <- function(work_id, sc_idx, ps_idx,
                               scenarios_dt, weather_cache_local,
                               param_sets_local, param_set_ids_local,
                               n_mc_draws_local, seed_base_local,
                               slurry_dists, fixed_slurry) {

  sc <- scenarios_dt[sc_idx]
  weather_dt <- weather_cache_local[[sc$scenario_id]]

  if (is.null(weather_dt)) {
    return(NULL)
  }

  # Get initial conditions
 temp_t0 <- weather_dt[ctime == 0, air.temp]
  wind_t0 <- weather_dt[ctime == 0, wind.2m]
  app_method <- if ("method" %in% names(sc)) sc$method else "ts"

  param_set_id <- param_set_ids_local[ps_idx]
  alfam2_pars <- param_sets_local[[ps_idx]]

  # Set seed for reproducibility
  set.seed(seed_base_local + sc_idx * 1000 + ps_idx)

  results_list <- vector("list", n_mc_draws_local)

  for (draw_idx in seq_len(n_mc_draws_local)) {
    # Sample slurry parameters (inline for speed)
    man_tan <- truncnorm::rtruncnorm(1, a = slurry_dists$man.tan$min,
                                      b = slurry_dists$man.tan$max,
                                      mean = slurry_dists$man.tan$mean,
                                      sd = slurry_dists$man.tan$sd)
    man_dm <- truncnorm::rtruncnorm(1, a = slurry_dists$man.dm$min,
                                     b = slurry_dists$man.dm$max,
                                     mean = slurry_dists$man.dm$mean,
                                     sd = slurry_dists$man.dm$sd)
    man_ph <- truncnorm::rtruncnorm(1, a = slurry_dists$man.ph$min,
                                     b = slurry_dists$man.ph$max,
                                     mean = slurry_dists$man.ph$mean,
                                     sd = slurry_dists$man.ph$sd)
    app_rate <- slurry_dists$app.rate$min +
                (slurry_dists$app.rate$max - slurry_dists$app.rate$min) *
                rbeta(1, slurry_dists$app.rate$alpha, slurry_dists$app.rate$beta)

    TAN_app <- man_tan * app_rate

    # Build ALFAM2 input
    dat <- data.frame(
      ctime = weather_dt$ctime,
      air.temp = weather_dt$air.temp,
      rain.rate = weather_dt$rain.rate,
      wind.2m = weather_dt$wind.2m,
      TAN.app = TAN_app,
      man.tan = man_tan,
      man.dm = man_dm,
      man.ph = man_ph,
      app.rate = app_rate,
      crop.z = fixed_slurry$crop.z,
      time.incorp = fixed_slurry$time.incorp,
      app.mthd = app_method,
      stringsAsFactors = FALSE
    )

    # Run ALFAM2
    res <- tryCatch({
      alfam_res <- suppressWarnings({
        ALFAM2::alfam2(dat = dat, pars = alfam2_pars,
                      app.name = "TAN.app", time.name = "ctime", check = FALSE)
      })
      e_final <- tail(alfam_res$e, 1)
      list(success = TRUE, e_frac = e_final, e_kg = (e_final / 100) * TAN_app)
    }, error = function(e) list(success = FALSE))

    if (res$success) {
      results_list[[draw_idx]] <- data.table(
        scenario_id = sc$scenario_id,
        param_set_id = param_set_id,
        mc_draw = draw_idx,
        station = sc$station,
        year = sc$year,
        date = sc$date,
        time_of_day = sc$time_of_day,
        period = if ("period" %in% names(sc)) sc$period else NA_character_,
        method = app_method,
        temp_t0 = temp_t0,
        wind_t0 = wind_t0,
        man_tan = man_tan,
        man_dm = man_dm,
        man_ph = man_ph,
        app_rate = app_rate,
        TAN_applied = TAN_app,
        emission_frac = res$e_frac,
        emission_kg_ha = res$e_kg
      )
    }
  }

  valid_results <- Filter(Negate(is.null), results_list)
  if (length(valid_results) > 0) {
    return(rbindlist(valid_results))
  }
  return(NULL)
}

# Process in batches for progress reporting
batch_size <- n_cores * 4  # Process 4 items per core per batch
n_batches <- ceiling(total_work_items / batch_size)

msg("\nProcessing in", n_batches, "batches of ~", batch_size, "work items each")
msg("Using", n_cores, "parallel workers\n")

pb <- txtProgressBar(min = 0, max = total_work_items, style = 3)
items_done <- 0
runs_success <- 0
runs_failed <- 0

for (batch_idx in seq_len(n_batches)) {
  batch_start <- (batch_idx - 1) * batch_size + 1
  batch_end <- min(batch_idx * batch_size, total_work_items)
  batch_items <- work_items[batch_start:batch_end]

  # Process batch in parallel
  batch_results <- future_lapply(
    seq_len(nrow(batch_items)),
    function(i) {
      item <- batch_items[i]
      process_work_item(
        work_id = item$work_id,
        sc_idx = item$sc_idx,
        ps_idx = item$ps_idx,
        scenarios_dt = scenarios,
        weather_cache_local = weather_cache,
        param_sets_local = param_sets,
        param_set_ids_local = param_set_ids,
        n_mc_draws_local = n_mc_draws,
        seed_base_local = seed_base,
        slurry_dists = SLURRY_DISTRIBUTIONS,
        fixed_slurry = FIXED_SLURRY
      )
    },
    future.seed = TRUE,
    future.packages = c("data.table", "ALFAM2", "truncnorm")
  )

  # Collect results
  valid_batch <- Filter(Negate(is.null), batch_results)
  if (length(valid_batch) > 0) {
    batch_dt <- rbindlist(valid_batch)
    fwrite(batch_dt, master_csv, append = TRUE)
    runs_success <- runs_success + nrow(batch_dt)
  }

  expected_runs <- nrow(batch_items) * n_mc_draws
  actual_runs <- if (length(valid_batch) > 0) nrow(batch_dt) else 0
  runs_failed <- runs_failed + (expected_runs - actual_runs)

  items_done <- items_done + nrow(batch_items)
  setTxtProgressBar(pb, items_done)

  # Status update every 10 batches
  if (batch_idx %% 10 == 0 || batch_idx == n_batches) {
    elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "mins"))
    rate <- items_done / elapsed
    remaining <- (total_work_items - items_done) / rate
    # Uncomment for verbose progress:
    # msg(sprintf("\n  Batch %d/%d: %.1f%% complete, ~%.1f min remaining",
    #             batch_idx, n_batches, 100 * items_done / total_work_items, remaining))
  }

  # Garbage collection every 20 batches
  if (batch_idx %% 20 == 0) gc(verbose = FALSE)
}

close(pb)

# -------------------- Summary Statistics ------------------------------------
msg("\n[STEP 6] Generating summary statistics...")

elapsed_total <- difftime(Sys.time(), start_time, units = "mins")
msg("Total runtime:", round(as.numeric(elapsed_total), 1), "minutes")
msg("Successful runs:", format(runs_success, big.mark = ","))
msg("Failed runs:", format(runs_failed, big.mark = ","))

# Calculate throughput
total_runs_actual <- runs_success + runs_failed
if (as.numeric(elapsed_total) > 0) {
  runs_per_min <- total_runs_actual / as.numeric(elapsed_total)
  runs_per_sec <- runs_per_min / 60
  msg("Throughput:", round(runs_per_min, 0), "runs/minute (", round(runs_per_sec, 1), "runs/second)")
}

# Load results for summary
if (file.exists(master_csv) && file.size(master_csv) > 0) {
  results <- fread(master_csv)

  if (nrow(results) > 0) {
    msg("\nResults summary:")
    msg("  Total predictions:", format(nrow(results), big.mark = ","))
    msg("  Mean emission:", round(mean(results$emission_kg_ha, na.rm = TRUE), 2), "kg NH3-N/ha")
    msg("  Mean emission fraction:", round(mean(results$emission_frac, na.rm = TRUE), 2), "% of TAN")

    # Summary by time of day
    tod_summary <- results[, .(
      n = .N,
      mean_emission = mean(emission_kg_ha, na.rm = TRUE),
      sd_emission = sd(emission_kg_ha, na.rm = TRUE),
      mean_frac = mean(emission_frac, na.rm = TRUE)
    ), by = time_of_day]

    msg("\nEmissions by time of day:")
    print(tod_summary)

    # Save summary
    fwrite(tod_summary, file.path(output_dir, "summary_by_time_of_day.csv"))

    # Summary by parameter set (for uncertainty analysis)
    param_summary <- results[, .(
      n = .N,
      mean_emission = mean(emission_kg_ha, na.rm = TRUE),
      sd_emission = sd(emission_kg_ha, na.rm = TRUE)
    ), by = param_set_id]

    fwrite(param_summary, file.path(output_dir, "summary_by_param_set.csv"))

    # -------------------- Generate Plots --------------------------------------
    msg("\n[STEP 7] Generating plots...")

    plots_dir <- file.path(output_dir, "plots")
    dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

    # Time of day comparison
    results[, time_of_day := factor(time_of_day, levels = c("morning", "afternoon", "evening"))]

    tod_colors <- c("morning" = "#56B4E9", "afternoon" = "#E69F00", "evening" = "#CC79A7")

    p1 <- ggplot(results, aes(x = time_of_day, y = emission_kg_ha, fill = time_of_day)) +
      geom_boxplot(alpha = 0.7, outlier.alpha = 0.1) +
      scale_fill_manual(values = tod_colors) +
      stat_summary(fun = mean, geom = "point", shape = 23, size = 3, fill = "red") +
      labs(
        title = "Ammonia Emissions by Time of Day",
        subtitle = sprintf("Based on %s Monte Carlo predictions", format(nrow(results), big.mark = ",")),
        x = "Application Time",
        y = expression("Emission (kg NH"[3]*"-N ha"^{-1}*")")
      ) +
      theme_bw() +
      theme(legend.position = "none",
            plot.title = element_text(face = "bold", size = 14),
            axis.title = element_text(size = 12))

    ggsave(file.path(plots_dir, "emission_by_time_of_day.png"), p1,
           width = 10, height = 7, dpi = 150, bg = "white")

    # Emission fraction distribution
    p2 <- ggplot(results, aes(x = emission_frac, fill = time_of_day)) +
      geom_density(alpha = 0.5) +
      scale_fill_manual(values = tod_colors) +
      labs(
        title = "Distribution of Emission Fractions",
        subtitle = "Percentage of applied TAN emitted as ammonia",
        x = "Emission Fraction (% of TAN)",
        y = "Density",
        fill = "Time of Day"
      ) +
      theme_bw() +
      theme(plot.title = element_text(face = "bold", size = 14),
            legend.position = "right")

    ggsave(file.path(plots_dir, "emission_fraction_density.png"), p2,
           width = 10, height = 7, dpi = 150, bg = "white")

    # Parameter uncertainty (if multiple param sets)
    if (length(unique(results$param_set_id)) > 1) {
      p3 <- ggplot(results, aes(x = param_set_id, y = emission_kg_ha)) +
        geom_boxplot(fill = "#2166AC", alpha = 0.6, outlier.alpha = 0.1) +
        labs(
          title = "Emission Uncertainty Across ALFAM2 Parameter Sets",
          x = "Parameter Set",
          y = expression("Emission (kg NH"[3]*"-N ha"^{-1}*")")
        ) +
        theme_bw() +
        theme(axis.text.x = element_text(angle = 90, hjust = 1, size = 6),
              plot.title = element_text(face = "bold", size = 14))

      ggsave(file.path(plots_dir, "emission_by_param_set.png"), p3,
             width = 12, height = 6, dpi = 150, bg = "white")
    }

    msg("Plots saved to:", plots_dir)
  }
}

# -------------------- Save Run Log ------------------------------------------
run_log <- data.table(
  timestamp = Sys.time(),
  run_mode = RUN_MODE,
  n_scenarios = nrow(scenarios[has_weather == TRUE]),
  n_param_sets = length(param_sets),
  n_mc_draws = n_mc_draws,
  total_runs = runs_success + runs_failed,
  successful_runs = runs_success,
  failed_runs = runs_failed,
  runtime_minutes = round(as.numeric(elapsed_total), 2),
  runs_per_minute = round(runs_success / as.numeric(elapsed_total), 0),
  n_cores_used = n_cores,
  seed = seed_base
)
fwrite(run_log, log_csv)

# -------------------- Final Summary -----------------------------------------
msg("\n" |> paste0(rep("=", 70) |> paste(collapse = "")))
msg("MONTE CARLO SIMULATION COMPLETE")
msg("=" |> rep(70) |> paste(collapse = ""))
msg("")
msg("Run Mode:", RUN_MODE)
msg("Total runtime:", round(as.numeric(elapsed_total), 1), "minutes")
msg("")
msg("KEY OUTPUTS:")
msg("  mc_results_master.csv      - All individual predictions")
msg("  summary_by_time_of_day.csv - Mean emissions by time block")
msg("  summary_by_param_set.csv   - Uncertainty by parameter set")
msg("  plots/                     - Diagnostic visualisations")
msg("")
msg("NEXT STEP: Run 04_analysis.R to answer research questions")
msg("=" |> rep(70) |> paste(collapse = ""))

# Cleanup
plan(sequential)
gc()
