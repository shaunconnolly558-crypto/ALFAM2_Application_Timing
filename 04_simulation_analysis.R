###############################################################################
# 04_simulation_analysis.R
#
# ALFAM2 Monte Carlo Simulation Analysis - HARMONISED MANUSCRIPT SCRIPT
#
# PURPOSE
#   Single, self-contained script that reproduces every simulation-derived
#   table and figure referenced in the submission manuscript ("Why timing
#   matters..." / ALFAM2 Irish paper). It supersedes the exploratory scripts
#   04a_research_analysis.R, 04c_supplementary_analyses.R and
#   04f_publication_figures.R for the purposes of the submitted paper: those
#   scripts remain useful for methodological exploration (parameter set
#   selection, GAMs, sensitivity analyses, reviewer responses) but this
#   script is the canonical source of the numbers and figures that appear
#   in the manuscript text/tables.
#
# INPUTS
#   output/03_monte_carlo_results/mc_results_master.csv
#     One row per scenario x parameter set x slurry Monte Carlo draw.
#     Columns (see 03_monte_carlo.R header_dt): scenario_id, param_set_id,
#     mc_draw, station, year, date, time_of_day, period, method, temp_t0,
#     wind_t0, man_tan, man_dm, man_ph, app_rate, TAN_applied, emission_frac,
#     emission_kg_ha.
#   output/02_scenario_generation/scenarios.csv
#     One row per station x date x time_of_day scenario (see
#     02_scenario_generator.R). Used here only for the Table 5 diurnal
#     temperature analysis (t0_air_temp per time block).
#
# OUTPUTS
#   output/04_analysis/tables/*.csv + *.docx   (all manuscript tables)
#   output/04_analysis/figures/*.png           (Figures 2 and 3)
#
# EMISSIONS OUTPUT CONVENTIONS (apply throughout this script)
#   - Every emission value is "emission_frac" = cumulative ammonia loss over
#     the full 168-hour (7-day) ALFAM2 simulation window, expressed as a
#     percentage of applied Total Ammoniacal Nitrogen (% TAN). It is a
#     CUMULATIVE, not instantaneous, quantity.
#   - Time resolution of the underlying simulation: 168-hour (7-day)
#     cumulative emission per application event.
#   - Spatial resolution: station-level (22 Met Eireann synoptic/weather
#     stations across Ireland) unless a table explicitly aggregates to
#     national scale (Part: National-scale savings estimate).
#   - Any value described as "mean" or "averaged" below is an
#     AGGREGATED/AVERAGED statistic taken across the dimension named in the
#     surrounding text (e.g. across Monte Carlo slurry draws, across the
#     101 ALFAM2 parameter sets, across scenarios/years) - never a raw
#     instantaneous simulation output.
#
###############################################################################

# ============================== USER SETTINGS ================================
# Everything you are likely to need to tweak between manuscript drafts lives
# in this block. File paths are relative to the project working directory
# (i.e. run this script with alfam2-ireland-timing/ as the working directory,
# or adjust PROJECT_ROOT below).

PROJECT_ROOT <- "."  # change if running from outside the project root

# ---- Input data paths --------------------------------------------------------
mc_results_path  <- file.path(PROJECT_ROOT, "output", "03_monte_carlo_results",
                               "mc_results_master.csv")
scenarios_path   <- file.path(PROJECT_ROOT, "output", "02_scenario_generation",
                               "scenarios.csv")

# ---- Output paths -------------------------------------------------------------
output_dir  <- file.path(PROJECT_ROOT, "output", "04_analysis")
tables_dir  <- file.path(output_dir, "tables")
figures_dir <- file.path(output_dir, "figures")

# ---- Central / reference ALFAM2 parameter set --------------------------------
# The manuscript reports a single "central" parameter set (alfam2pars03,
# i.e. the ALFAM2 package's built-in parameter set 3) alongside the full
# 101-parameter-set ensemble used for uncertainty quantification. Update
# this if your mc_results_master.csv uses a different label for the central
# set (older runs of 03_monte_carlo.R used "ps000_central").
CENTRAL_PARAM_SET_ID <- "alfam2pars03"
CENTRAL_PARAM_SET_FALLBACKS <- c("ps000_central", "alfam2pars03", "ps000")

# ---- Irish national inventory reference values (Section 3.2 / Table 3) -------
# Source: Irish EPA National Inventory / Informative Inventory Report (IIR).
# Base splashplate (broadcast) emission factors by season, and the trailing
# shoe abatement factor currently assumed in the national inventory, are
# used only to DERIVE the season inventory targets for cross-checking; the
# manuscript's Table 3 values themselves are hardcoded below as
# INVENTORY_TARGET_PCT_TAN so the table is robust to any future change in
# how the derivation constants are interpreted.
SPLASHPLATE_SUMMER        <- 48.0   # % TAN loss, summer, splashplate/broadcast
SPLASHPLATE_SPRING_AUTUMN <- 26.0   # % TAN loss, spring/autumn, splashplate
ABATEMENT_CURRENT         <- 0.45   # trailing shoe abatement vs splashplate (IIR)

# Manuscript Table 3 "Inventory Value (% TAN)" by season - hardcoded exactly
# as reported in the manuscript. These should equal SPLASHPLATE_x * (1 -
# ABATEMENT_CURRENT); the script asserts this below and warns if they drift.
INVENTORY_TARGET_PCT_TAN <- c(spring = 14.3, summer = 26.4, autumn = 14.3)

# ---- National-scale savings estimate (Section 4.6 / Part: National Savings) --
# Source: Irish EPA National Inventory Report, most recent year available at
# time of writing (2024 inventory year). Update these constants when a new
# inventory is published.
NATIONAL_NH3_FIELD_APPLICATION_KT      <- 31.47  # kt NH3/yr from field-applied manure (2024)
NATIONAL_NH3_FIELD_APPLICATION_PCT_TOT <- 27.1   # field application as % of national NH3 total
MANUSCRIPT_REDUCTION_PCT               <- 6.1    # manuscript-stated relative reduction from evening shift (%)
MANUSCRIPT_SAVING_KT_CURRENT           <- 2.0    # manuscript-stated ~2 kt/yr saving (sanity check target)
MANUSCRIPT_SAVING_KT_2050              <- 2.2    # manuscript-stated ~2.2 kt by 2050 (herd-growth extrapolation;
                                                  # NOT re-derived here - no herd-growth projection is part of
                                                  # the MC dataset, so this is retained as a stated reference
                                                  # figure rather than computed from mc_results_master.csv)

# ---- Climate projection settings (Table 6, Section 3.5) ----------------------
# Temperature change scenarios (deg C above the simulated baseline period)
# used to linearly extrapolate mean emission factor and evening advantage.
# These are illustrative RCP/SSP-consistent mid-century warming increments,
# NOT derived from a climate model run through ALFAM2 - see the code comment
# at Table 6 for the important limitation this implies.
CLIMATE_PERIODS       <- c("Current", "2030s", "2040s", "2050s", "2060s", "2070s", "2080s")
CLIMATE_TEMP_CHANGE_C <- c(0, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75)

# ---- Statistical / computational settings -------------------------------------
CONFIDENCE_LEVEL <- 0.95
SEED <- 42
N_CORES <- max(1, parallel::detectCores(logical = FALSE) - 1)  # not heavily used;
                                                                 # this script is dominated by
                                                                 # data.table aggregation, which
                                                                 # is already fast/vectorised and
                                                                 # does not benefit from explicit
                                                                 # parallelisation here.

# ---- Figure settings (per project Figure Style Specification) ----------------
FIG_WIDTH_MM  <- 170
FIG_HEIGHT_MM <- 100
fig_width_in  <- FIG_WIDTH_MM / 25.4
fig_height_in <- FIG_HEIGHT_MM / 25.4
FIG_DPI       <- 300

# Colour-blind friendly time-of-day palette (Figure Style Specification) -
# used for any NEW categorical time-of-day plots added in this script.
# Figures 2 and 3 keep the specific colours from 04f_publication_figures.R
# (reused near-verbatim) because those are already finalised for the paper.
tod_colors_cb <- c("morning" = "#E69F00", "afternoon" = "#56B4E9", "evening" = "#009E73")
season_colors <- c("spring" = "#7FBC41", "summer" = "#FE9929",
                    "autumn" = "#D73027", "winter" = "#4575B4")
color_vs_morning   <- "#2166AC"
color_vs_afternoon <- "#B2182B"
color_emissions    <- "#2166AC"
color_advantage    <- "#D6604D"

# ---- Static reference table: Table S3 Nitrates Action Programme calendar -----
# Source: S.I. No. 113 of 2022 (European Union (Good Agricultural Practice
# for Protection of Waters) Regulations 2022), Schedule setting out the
# closed period for organic fertiliser spreading by zone.
#
# NOTE ON APPARENT DUPLICATION: Leitrim, Cavan and Monaghan appear in BOTH
# Zone A and Zone C in the manuscript's Table S3, verbatim. This looks like
# it could be a manuscript transcription issue (e.g. intended to show only
# in Zone C, since Zone C's closed period is a strict superset/refinement
# of Zone A's for those three counties), OR it could genuinely reflect how
# the SI groups counties (Zone C zones nested within Zone A's broader
# grouping for some purposes). We preserve the manuscript table EXACTLY as
# supplied so this script's output matches the submitted paper, but flag
# this here so you can verify the county list against the statutory
# instrument text before final submission/publication.
table_s3_nap <- data.frame(
  Zone = c("A", "B", "C"),
  Counties = c(
    "Cork, Kerry, Limerick, Clare, Galway, Mayo, Roscommon, Sligo, Leitrim, Donegal, Cavan, Monaghan",
    "Tipperary, Waterford, Kilkenny, Wexford, Carlow, Wicklow, Kildare, Laois, Offaly, Westmeath, Longford, Meath, Louth, Dublin",
    "Leitrim, Cavan, Monaghan"
  ),
  `Closed period` = c("15 Oct - 12 Jan", "15 Oct - 15 Jan", "15 Oct - 31 Jan"),
  `Open period`   = c("13 Jan - 14 Oct", "16 Jan - 14 Oct", "1 Feb - 14 Oct"),
  check.names = FALSE,
  stringsAsFactors = FALSE
)

# ================================ PACKAGES =====================================

required_packages <- c(
  "data.table", "ggplot2", "scales", "flextable", "officer", "lubridate"
)
for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org/")
  }
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
}

# ================================ HELPERS ======================================

msg <- function(...) cat("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ", ..., "\n", sep = "")

ensure_dir <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE, showWarnings = FALSE)
    msg("Created directory: ", path)
  }
}

# Publication ggplot theme (white background, minimal gridlines, thin black
# axes) - Figure Style Specification.
theme_pub <- function(base_size = 11) {
  theme_bw(base_size = base_size) +
    theme(
      plot.background   = element_rect(fill = "white", color = NA),
      panel.background  = element_rect(fill = "white", color = NA),
      panel.grid.minor  = element_blank(),
      panel.grid.major  = element_line(color = "grey85", linewidth = 0.3),
      axis.line         = element_line(color = "black", linewidth = 0.3),
      plot.title        = element_text(face = "bold", size = base_size + 1, hjust = 0),
      plot.subtitle     = element_text(size = base_size - 1, color = "grey30"),
      axis.title        = element_text(size = base_size),
      legend.position   = "bottom",
      legend.background = element_blank(),
      legend.key        = element_blank()
    )
}

# ------------------------------------------------------------------------------
# export_table(): the single helper used for every manuscript table so that
# csv + Word output are always produced together and always follow the
# project's Table Formatting Specification:
#   - three-line table (top rule / header rule / bottom rule), no vertical
#     lines, no row shading (flextable::theme_booktabs achieves this)
#   - bold header row
#   - left-align text columns, centre-align numeric columns
#   - column names should already be "display ready" (units in parentheses,
#     no underscores) BEFORE calling this function
# ------------------------------------------------------------------------------
export_table <- function(dt, filename, tables_dir,
                          notes = "TAN = total ammoniacal nitrogen; pp = percentage points; CI = confidence interval.",
                          caption = NULL) {
  dt <- as.data.frame(dt)
  fwrite(dt, file.path(tables_dir, paste0(filename, ".csv")))

  ft <- flextable::flextable(dt)
  ft <- flextable::theme_booktabs(ft)               # three-line style, no vertical rules
  ft <- flextable::bold(ft, part = "header")
  ft <- flextable::valign(ft, valign = "top", part = "header")

  is_text_col <- vapply(dt, function(x) is.character(x) || is.factor(x), logical(1))
  text_cols <- names(dt)[is_text_col]
  num_cols  <- names(dt)[!is_text_col]
  if (length(text_cols) > 0) ft <- flextable::align(ft, j = text_cols, align = "left",   part = "all")
  if (length(num_cols)  > 0) ft <- flextable::align(ft, j = num_cols,  align = "center", part = "all")

  if (!is.null(caption)) {
    ft <- flextable::add_header_lines(ft, values = caption)
    ft <- flextable::bold(ft, i = 1, part = "header")
  }
  if (!is.null(notes)) {
    ft <- flextable::add_footer_lines(ft, values = notes)
    ft <- flextable::fontsize(ft, size = 8, part = "footer")
    ft <- flextable::italic(ft, part = "footer")
  }
  ft <- flextable::autofit(ft)

  flextable::save_as_docx(ft, path = file.path(tables_dir, paste0(filename, ".docx")))
  msg("  Saved table: ", filename, ".csv / .docx")
  invisible(ft)
}

# ================================ MAIN SCRIPT ==================================

msg(paste(rep("=", 78), collapse = ""))
msg("ALFAM2 IRELAND - HARMONISED MANUSCRIPT SIMULATION ANALYSIS")
msg(paste(rep("=", 78), collapse = ""))

set.seed(SEED)
ensure_dir(output_dir); ensure_dir(tables_dir); ensure_dir(figures_dir)

# --------------------------------------------------------------------------
# Verify the Table 3 inventory targets are internally consistent with the
# derivation constants (splashplate EF x (1 - abatement)). This is a sanity
# check on the USER SETTINGS block itself, not on simulation data.
# --------------------------------------------------------------------------
derived_summer <- SPLASHPLATE_SUMMER * (1 - ABATEMENT_CURRENT)
derived_sa     <- SPLASHPLATE_SPRING_AUTUMN * (1 - ABATEMENT_CURRENT)
if (abs(derived_summer - INVENTORY_TARGET_PCT_TAN["summer"]) > 0.05 ||
    abs(derived_sa - INVENTORY_TARGET_PCT_TAN["spring"]) > 0.05) {
  msg("WARNING: INVENTORY_TARGET_PCT_TAN in USER SETTINGS does not match ",
      "SPLASHPLATE_x * (1 - ABATEMENT_CURRENT). Check these constants.")
}

###############################################################################
# SECTION 1 (data loading) -----------------------------------------------------
###############################################################################

msg("\n[SECTION 1] Loading Monte Carlo results and scenario metadata")

if (!file.exists(mc_results_path)) stop("Monte Carlo results not found: ", mc_results_path)
mc_dt <- fread(mc_results_path)
msg("Loaded ", format(nrow(mc_dt), big.mark = ","), " simulation rows from mc_results_master.csv")
msg("Columns: ", paste(names(mc_dt), collapse = ", "))

# ---- Flexible column-name mapping (defensive against upstream renames) -------
avail <- names(mc_dt)
TEMP_COL <- if ("temp_t0" %in% avail) "temp_t0" else if ("temp0" %in% avail) "temp0" else NA
WIND_COL <- if ("wind_t0" %in% avail) "wind_t0" else if ("wind0" %in% avail) "wind0" else NA
RUN_COL  <- if ("mc_draw" %in% avail) "mc_draw" else if ("run_id" %in% avail) "run_id" else NA

required_cols <- c("scenario_id", "param_set_id", "station", "year", "date",
                    "time_of_day", "emission_frac")
missing_req <- setdiff(required_cols, avail)
if (is.na(TEMP_COL)) missing_req <- c(missing_req, "temp_t0/temp0")
if (length(missing_req) > 0) stop("Missing required columns in mc_results_master.csv: ",
                                   paste(missing_req, collapse = ", "))

if (TEMP_COL != "temp0") setnames(mc_dt, TEMP_COL, "temp0", skip_absent = TRUE)
if (!is.na(WIND_COL) && WIND_COL != "wind0") setnames(mc_dt, WIND_COL, "wind0", skip_absent = TRUE)
if (!is.na(RUN_COL) && RUN_COL != "run_id") setnames(mc_dt, RUN_COL, "run_id", skip_absent = TRUE)

mc_dt[, `:=`(
  date = as.Date(date),
  year = as.integer(year),
  emission_frac = as.numeric(emission_frac),
  temp0 = as.numeric(temp0)
)]
if ("wind0" %in% names(mc_dt)) mc_dt[, wind0 := as.numeric(wind0)]

mc_dt[, `:=`(
  month = factor(month(date), levels = 1:12, labels = month.abb),
  month_num = month(date),
  season = factor(
    fcase(
      month(date) %in% c(3, 4, 5),  "spring",
      month(date) %in% c(6, 7, 8),  "summer",
      month(date) %in% c(9, 10, 11), "autumn",
      default = "winter"
    ),
    levels = c("spring", "summer", "autumn", "winter")
  ),
  time_of_day = factor(time_of_day, levels = c("morning", "afternoon", "evening"))
)]

# Clean data: drop rows with missing/non-physical emission fractions
n_before <- nrow(mc_dt)
mc_dt <- mc_dt[!is.na(emission_frac) & emission_frac > 0]
if (n_before - nrow(mc_dt) > 0) {
  msg("Removed ", format(n_before - nrow(mc_dt), big.mark = ","),
      " rows with invalid/non-positive emission_frac")
}

msg("Scenarios: ", uniqueN(mc_dt$scenario_id),
    " | Parameter sets: ", uniqueN(mc_dt$param_set_id),
    " | Stations: ", uniqueN(mc_dt$station),
    " | Years: ", min(mc_dt$year), "-", max(mc_dt$year))

# ---- Identify the central parameter set --------------------------------------
central_ps_candidates <- CENTRAL_PARAM_SET_FALLBACKS[CENTRAL_PARAM_SET_FALLBACKS %in% unique(mc_dt$param_set_id)]
if (length(central_ps_candidates) == 0) {
  msg("WARNING: none of the expected central parameter set labels (",
      paste(CENTRAL_PARAM_SET_FALLBACKS, collapse = ", "),
      ") were found in param_set_id. Falling back to the parameter set with ",
      "the emission-fraction mean closest to the overall ensemble mean.")
  ps_means <- mc_dt[, .(mean_ef = mean(emission_frac, na.rm = TRUE)), by = param_set_id]
  overall_mean <- mean(mc_dt$emission_frac, na.rm = TRUE)
  CENTRAL_PS <- ps_means[order(abs(mean_ef - overall_mean))][1, param_set_id]
} else {
  CENTRAL_PS <- central_ps_candidates[1]
}
msg("Central parameter set identified as: ", CENTRAL_PS)

# ---- Load scenario metadata (for Table 5 diurnal temperature analysis) -------
scenarios_dt <- NULL
if (file.exists(scenarios_path)) {
  scenarios_dt <- fread(scenarios_path)
  scenarios_dt[, date := as.Date(date)]
  msg("Loaded ", nrow(scenarios_dt), " scenario metadata rows from scenarios.csv")
} else {
  msg("WARNING: scenarios.csv not found at ", scenarios_path,
      " - Table 5 (diurnal temperature quintiles) will be skipped.")
}

###############################################################################
# TABLE 1 - Slurry property distributions (static reference table)
# Source: SLURRY_DISTRIBUTIONS in 03_monte_carlo.R, cross-checked against
# the manuscript's more precise 2-dp summary moments.
###############################################################################

msg("\n[TABLE 1] Slurry property distributions")

# NOTE ON app.rate DISTRIBUTION MISMATCH:
#   03_monte_carlo.R samples application rate from a Beta distribution
#   scaled to [min=25, max=43] m3/ha (alpha=3.0, beta=2.5; implied mean
#   ~34.8 m3/ha). The manuscript prose instead states "a mean of 33 m3/ha
#   and standard deviation of 10.3 m3/ha (range 11.6 to 56.0)" and labels
#   the distribution "Trunc. Normal" in Table 1 - a materially WIDER range
#   than the working MC code actually samples from. Changing the Monte
#   Carlo sampling itself is out of scope for this analysis script (that
#   would require re-running 03_monte_carlo.R with different distribution
#   parameters and is a decision for the modelling/methods step, not the
#   analysis step). We therefore:
#     (a) leave the actual simulation-generating distribution untouched
#         (Beta, [25,43] m3/ha) - the TAN.app values below approximate this
#         if raw slurry draws are available in mc_results_master.csv, and
#     (b) report Table 1 using the manuscript's STATED target moments
#         (mean 33.0, SD 10.3, min 11.6, max 56.0) so the printed table
#         matches the submitted manuscript text.
#   You should verify against your Supplementary Information which of (a)
#   the code or (b) the manuscript prose is the intended ground truth
#   before final submission - this is flagged here rather than silently
#   resolved because it changes the reported spreading-rate variability
#   used to interpret Table 1's derived TAN.app row.
APP_RATE_SIM_MIN_M3HA <- 25; APP_RATE_SIM_MAX_M3HA <- 43  # as coded in 03_monte_carlo.R

slurry_dist_static <- list(
  # NOTE: 03_monte_carlo.R itself uses mean=6.4, sd=1.2, min=3.0, max=10.7 for
  # man.dm; the manuscript Table 1 rounds/refits to 2 dp (6.39/1.22/2.99/10.70)
  # from the underlying Irish literature fit. Both are consistent to 1 dp;
  # we report the manuscript's more precise values here.
  TAN  = c(mean = 1.32,  sd = 0.51,  min = 0.46, max = 2.24),
  DM   = c(mean = 6.39,  sd = 1.22,  min = 2.99, max = 10.70),
  pH   = c(mean = 7.30,  sd = 0.22,  min = 6.80, max = 7.97),
  Rate = c(mean = 33.0,  sd = 10.3,  min = 11.6, max = 56.0)   # manuscript-stated moments; see note above
)

# Derived quantity: TAN applied (kg/ha) = TAN concentration (kg/t) x app
# rate (m3/ha, taken as approx t/ha for slurry density ~1). Compute this
# from the actual Monte Carlo slurry draws in mc_results_master.csv where
# available (man_tan, app_rate, TAN_applied columns from 03_monte_carlo.R),
# which is the physically consistent approach; fall back to the
# manuscript-reported summary if those columns are absent.
if (all(c("man_tan", "app_rate") %in% names(mc_dt))) {
  tan_app_vec <- mc_dt[, if ("TAN_applied" %in% names(mc_dt)) TAN_applied else man_tan * app_rate]
  tan_app_stats <- c(mean = mean(tan_app_vec, na.rm = TRUE),
                      sd   = sd(tan_app_vec, na.rm = TRUE),
                      min  = min(tan_app_vec, na.rm = TRUE),
                      max  = max(tan_app_vec, na.rm = TRUE))
  msg("  TAN applied (kg/ha) computed from mc_results_master.csv slurry draws.")
} else {
  msg("  man_tan/app_rate columns not found - using manuscript-reported TAN.app summary (hardcoded).")
  tan_app_stats <- c(mean = 43.5, sd = 22.2, min = 5.3, max = 125.5)
}
slurry_dist_static$`TAN app` <- tan_app_stats

table1 <- data.frame(
  Parameter = c("TAN (kg t-1)", "DM (%)", "pH", "App. rate (m3 ha-1)", "TAN app. (kg ha-1)"),
  Distribution = c("Trunc. Normal", "Trunc. Normal", "Trunc. Normal", "Trunc. Normal (stated; sampled as Beta - see code comment)", "Derived"),
  `Mean` = sprintf("%.2f", c(slurry_dist_static$TAN["mean"], slurry_dist_static$DM["mean"],
                              slurry_dist_static$pH["mean"], slurry_dist_static$Rate["mean"],
                              slurry_dist_static$`TAN app`["mean"])),
  `SD` = sprintf("%.2f", c(slurry_dist_static$TAN["sd"], slurry_dist_static$DM["sd"],
                            slurry_dist_static$pH["sd"], slurry_dist_static$Rate["sd"],
                            slurry_dist_static$`TAN app`["sd"])),
  `Min` = sprintf("%.2f", c(slurry_dist_static$TAN["min"], slurry_dist_static$DM["min"],
                             slurry_dist_static$pH["min"], slurry_dist_static$Rate["min"],
                             slurry_dist_static$`TAN app`["min"])),
  `Max` = sprintf("%.2f", c(slurry_dist_static$TAN["max"], slurry_dist_static$DM["max"],
                             slurry_dist_static$pH["max"], slurry_dist_static$Rate["max"],
                             slurry_dist_static$`TAN app`["max"])),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table1)
export_table(table1, "Table1_slurry_property_distributions", tables_dir,
             notes = "TAN = total ammoniacal nitrogen; DM = dry matter; SD = standard deviation. Application rate: manuscript-stated target moments; underlying Monte Carlo sampling uses a Beta distribution (see script comments). TAN applied is a derived quantity (TAN concentration x application rate).")

###############################################################################
# TABLE 2 - Parameter set characterisation (Section 3.1)
###############################################################################

msg("\n[TABLE 2] Parameter set characterisation (n = 101 parameter sets)")

# Compute parameter-set-level MEANS first (one mean per param_set_id,
# averaged across all scenarios x slurry draws for that parameter set),
# then summarise the DISTRIBUTION OF THOSE MEANS across parameter sets.
# This two-stage aggregation is what the manuscript's "SD across parameter
# sets" refers to - it captures between-parameter-set (structural/ALFAM2
# calibration) uncertainty, as distinct from within-parameter-set
# (weather/slurry draw) variability.
ps_means <- mc_dt[, .(mean_ef = mean(emission_frac, na.rm = TRUE), n = .N), by = param_set_id]

n_param_sets      <- uniqueN(mc_dt$param_set_id)
total_predictions <- nrow(mc_dt)
mean_of_ps_means   <- mean(ps_means$mean_ef)
sd_of_ps_means     <- sd(ps_means$mean_ef)
median_of_ps_means <- median(ps_means$mean_ef)
min_ps_mean        <- min(ps_means$mean_ef)
max_ps_mean        <- max(ps_means$mean_ef)
central_ps_mean    <- ps_means[param_set_id == CENTRAL_PS, mean_ef]

table2 <- data.frame(
  Metric = c("Number of parameter sets", "Total predictions",
             "Mean emission (% TAN)", "SD (% TAN)", "Median (% TAN)",
             "Min parameter-set mean (% TAN)", "Max parameter-set mean (% TAN)",
             paste0("Central set (", CENTRAL_PS, ") mean (% TAN)")),
  Value = c(format(n_param_sets, big.mark = ","), format(total_predictions, big.mark = ","),
            sprintf("%.2f", mean_of_ps_means), sprintf("%.2f", sd_of_ps_means),
            sprintf("%.2f", median_of_ps_means), sprintf("%.2f", min_ps_mean),
            sprintf("%.2f", max_ps_mean), sprintf("%.2f", central_ps_mean)),
  stringsAsFactors = FALSE
)
print(table2)
export_table(table2, "Table2_parameter_set_characterisation", tables_dir,
             notes = "Statistics computed across the mean emission fraction (% TAN, 168-hour cumulative) of each of the 101 ALFAM2 parameter sets, each itself averaged across all scenarios and slurry Monte Carlo draws for that parameter set.")

###############################################################################
# TABLE 3 - Comparison with Irish inventory (Section 3.2)
# Uses the FULL parameter-set ensemble (all 101 sets x all slurry draws),
# consistent with Table 2's ensemble-uncertainty framing: the manuscript's
# headline emission factors integrate over ALFAM2 parameter uncertainty
# rather than conditioning on one "best" parameter set (that conditioning
# exercise is done separately in 04a_research_analysis.R for the parameter
# SELECTION methodology, which is out of scope here).
###############################################################################

msg("\n[TABLE 3] Comparison with Irish national inventory (by season)")

inv_seasons <- c("spring", "summer", "autumn")
season_ens_stats <- mc_dt[season %in% inv_seasons, .(
  n = .N,
  mean_ef = mean(emission_frac, na.rm = TRUE),
  sd_ef   = sd(emission_frac, na.rm = TRUE),
  q05     = quantile(emission_frac, 0.05, na.rm = TRUE),
  q95     = quantile(emission_frac, 0.95, na.rm = TRUE)
), by = season]
season_ens_stats[, season := as.character(season)]
season_ens_stats[, inventory_value := INVENTORY_TARGET_PCT_TAN[season]]
season_ens_stats[, deviation := mean_ef - inventory_value]
season_ens_stats <- season_ens_stats[match(c("spring", "summer", "autumn"), season)]

table3 <- data.frame(
  Season = tools::toTitleCase(season_ens_stats$season),
  `Inventory Value (% TAN)` = sprintf("%.1f", season_ens_stats$inventory_value),
  `ALFAM2 Mean (% TAN)` = sprintf("%.2f", season_ens_stats$mean_ef),
  `ALFAM2 SD (% TAN)`   = sprintf("%.2f", season_ens_stats$sd_ef),
  `5th-95th Percentile (% TAN)` = sprintf("%.2f to %.2f", season_ens_stats$q05, season_ens_stats$q95),
  `ALFAM2 Deviation (pp)` = sprintf("%+.2f", season_ens_stats$deviation),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table3)
export_table(table3, "Table3_inventory_comparison", tables_dir,
             notes = "Emission values are 168-hour cumulative % TAN loss, aggregated (mean/SD/percentile) across all 101 ALFAM2 parameter sets and all slurry Monte Carlo draws within each season, station-level simulations pooled to national scale. Inventory Value = current Irish national inventory trailing-shoe target (45% abatement vs splashplate baseline). Deviation = ALFAM2 mean minus Inventory Value.")

###############################################################################
# TABLE 4 - Mean emission by time of day and season (Section 3.3)
###############################################################################

msg("\n[TABLE 4] Mean emission by time of day and season")

tod_season_ens <- mc_dt[season %in% inv_seasons, .(
  mean_ef = mean(emission_frac, na.rm = TRUE)
), by = .(season, time_of_day)]

tod_overall_ens <- mc_dt[season %in% inv_seasons, .(
  mean_ef = mean(emission_frac, na.rm = TRUE)
), by = time_of_day]
tod_overall_ens[, season := "overall"]

tod_wide <- dcast(rbind(tod_season_ens, tod_overall_ens, use.names = TRUE),
                   season ~ time_of_day, value.var = "mean_ef")
tod_wide[, season := factor(season, levels = c("spring", "summer", "autumn", "overall"))]
tod_wide <- tod_wide[order(season)]

table4 <- data.frame(
  Season = tools::toTitleCase(as.character(tod_wide$season)),
  `Morning (% TAN)`   = sprintf("%.2f", tod_wide$morning),
  `Afternoon (% TAN)` = sprintf("%.2f", tod_wide$afternoon),
  `Evening (% TAN)`   = sprintf("%.2f", tod_wide$evening),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table4)
export_table(table4, "Table4_emission_by_timeofday_season", tables_dir,
             notes = "Group means of 168-hour cumulative % TAN loss across all 101 ALFAM2 parameter sets and all slurry Monte Carlo draws, station-level simulations pooled nationally. 'Overall' = spring+summer+autumn pooled (winter excluded - see closed-period calendar, Table S3).")

###############################################################################
# SECTION 3.3 NARRATIVE STATISTICS (printed, not just tabulated)
###############################################################################

msg("\n[SECTION 3.3] Narrative statistics: time-of-day / evening advantage")

# ---- (a) Parameter-set-level mean +/- 95% CI for morning/afternoon/evening ---
# Two-stage aggregation: first collapse to one mean per (param_set_id,
# time_of_day), THEN summarise the resulting 101 values per time block. The
# resulting CI reflects uncertainty IN THE PARAMETER SET (n=101), not the
# much larger apparent precision you'd get from treating every individual
# simulation row as an independent replicate.
ps_tod_means <- mc_dt[, .(mean_ef = mean(emission_frac, na.rm = TRUE)), by = .(param_set_id, time_of_day)]
tod_ps_summary <- ps_tod_means[, .(
  n_param_sets = .N,
  mean_ef = mean(mean_ef),
  sd_ef   = sd(mean_ef),
  se_ef   = sd(mean_ef) / sqrt(.N)
), by = time_of_day]
tod_ps_summary[, `:=`(
  ci_lower = mean_ef - qt(0.975, n_param_sets - 1) * se_ef,
  ci_upper = mean_ef + qt(0.975, n_param_sets - 1) * se_ef
)]
tod_ps_summary <- tod_ps_summary[order(time_of_day)]
cat("\nMean emission fraction by time of day, averaged across 101 parameter sets (95% CI reflects\n",
    "parameter-set uncertainty, n=101, not full predictive spread):\n", sep = "")
print(tod_ps_summary[, .(time_of_day, mean_ef = round(mean_ef, 2),
                          ci95 = sprintf("[%.2f, %.2f]", ci_lower, ci_upper))])

morn_pm <- tod_ps_summary[time_of_day == "morning", mean_ef]
aft_pm  <- tod_ps_summary[time_of_day == "afternoon", mean_ef]
eve_pm  <- tod_ps_summary[time_of_day == "evening", mean_ef]

adv_vs_morning_pp  <- morn_pm - eve_pm
adv_vs_afternoon_pp <- aft_pm - eve_pm
adv_vs_morning_rel  <- 100 * adv_vs_morning_pp / morn_pm
adv_vs_afternoon_rel <- 100 * adv_vs_afternoon_pp / aft_pm

cat(sprintf("\nEvening advantage (parameter-set-mean basis):\n"))
cat(sprintf("  vs morning:   %.2f pp (%.1f%% relative reduction)\n", adv_vs_morning_pp, adv_vs_morning_rel))
cat(sprintf("  vs afternoon: %.2f pp (%.1f%% relative reduction)\n", adv_vs_afternoon_pp, adv_vs_afternoon_rel))

# ---- (b) Central parameter set only -------------------------------------------
central_tod <- mc_dt[param_set_id == CENTRAL_PS, .(mean_ef = mean(emission_frac, na.rm = TRUE)), by = time_of_day]
central_morn <- central_tod[time_of_day == "morning", mean_ef]
central_aft  <- central_tod[time_of_day == "afternoon", mean_ef]
central_eve  <- central_tod[time_of_day == "evening", mean_ef]
cat(sprintf("\nCentral parameter set (%s) evening advantage:\n", CENTRAL_PS))
cat(sprintf("  vs morning:   %.2f pp (%.1f%% relative)\n", central_morn - central_eve, 100*(central_morn - central_eve)/central_morn))
cat(sprintf("  vs afternoon: %.2f pp (%.1f%% relative)\n", central_aft - central_eve, 100*(central_aft - central_eve)/central_aft))

# ---- (c) Scenario-level optimality ---------------------------------------------
# Scenario = one station x date combination (i.e. one "application day" at
# one weather station). We aggregate ACROSS all 101 parameter sets and all
# slurry draws to get a single mean emission per (station, date,
# time_of_day), then determine which of the three application times gives
# the lowest mean at that station-date. We deliberately key this on
# (station, date) rather than scenario_id: in scenarios.csv/mc_results
# scenario_id is generated per (station, date, time_of_day) triple (see
# 02_scenario_generator.R), so it is 1:1 with time_of_day and cannot be
# used as the pairing key for a morning/afternoon/evening comparison -
# (station, date) is the correct "application day" grain matching the
# manuscript's ~1,358 date-station combinations and the scenario-level
# tables used in 04b_reviewer_response_analysis.R.
scenario_tod <- mc_dt[, .(mean_ef = mean(emission_frac, na.rm = TRUE)),
                       by = .(station, date, season, time_of_day)]
scenario_wide <- dcast(scenario_tod, station + date + season ~ time_of_day, value.var = "mean_ef")
scenario_wide <- scenario_wide[!is.na(morning) & !is.na(afternoon) & !is.na(evening)]

n_scenarios <- nrow(scenario_wide)
msg("Scenario-level (station x date) rows with all three time blocks present: ", n_scenarios)

scenario_wide[, `:=`(
  best_time = fcase(
    morning <= afternoon & morning <= evening, "morning",
    afternoon <= evening, "afternoon",
    default = "evening"
  ),
  evening_is_best = (evening <= morning) & (evening <= afternoon),
  evening_vs_morning = morning - evening,
  evening_vs_afternoon = afternoon - evening
)]

pct_evening_best_overall <- 100 * mean(scenario_wide$evening_is_best)
pct_evening_best_by_season <- scenario_wide[season %in% inv_seasons, .(
  pct_evening_best = 100 * mean(evening_is_best)
), by = season]

cat(sprintf("\nScenario-level optimality: evening is the lowest-emission time in %.1f%% of %d scenarios overall.\n",
            pct_evening_best_overall, n_scenarios))
print(pct_evening_best_by_season)

# ---- (d) Per parameter set: how many of the 101 favour evening ---------------
param_evening_prob <- mc_dt[, {
  sc <- .SD[, .(mean_ef = mean(emission_frac, na.rm = TRUE)), by = .(station, date, time_of_day)]
  sc_w <- dcast(sc, station + date ~ time_of_day, value.var = "mean_ef")
  sc_w <- sc_w[!is.na(morning) & !is.na(afternoon) & !is.na(evening)]
  .(prob_evening_best = mean((sc_w$evening <= sc_w$morning) & (sc_w$evening <= sc_w$afternoon)),
    mean_evening_advantage = mean(pmax(sc_w$morning, sc_w$afternoon) - sc_w$evening))
}, by = param_set_id]

n_ps_evening_best <- sum(param_evening_prob$prob_evening_best > 0.5)
cat(sprintf("\nOf the %d parameter sets, evening is on average the best application time in %d of them (P(evening best) > 50%%).\n",
            n_param_sets, n_ps_evening_best))
cat(sprintf("Range of mean evening advantage across parameter sets: %.2f to %.2f %% TAN\n",
            min(param_evening_prob$mean_evening_advantage), max(param_evening_prob$mean_evening_advantage)))

param_evening_prob_display <- data.frame(
  `Parameter Set` = as.character(param_evening_prob$param_set_id),
  `P(evening best)` = sprintf("%.1f%%", 100 * param_evening_prob$prob_evening_best),
  `Mean evening advantage (% TAN)` = sprintf("%.2f", param_evening_prob$mean_evening_advantage),
  check.names = FALSE, stringsAsFactors = FALSE
)
export_table(param_evening_prob_display,
             "SuppTable_evening_advantage_by_parameter_set", tables_dir,
             notes = "Per-parameter-set probability that evening application gives the lowest mean 168-hour cumulative %TAN loss, and the mean evening advantage (pp), each computed across scenarios (station x date) using that parameter set's slurry Monte Carlo draws only.")

# ---- (e) Per station: is evening optimal everywhere? --------------------------
station_tod <- mc_dt[, .(mean_ef = mean(emission_frac, na.rm = TRUE)), by = .(station, time_of_day)]
station_wide <- dcast(station_tod, station ~ time_of_day, value.var = "mean_ef")
station_wide[, evening_best := (evening <= morning) & (evening <= afternoon)]
n_stations <- nrow(station_wide)
n_stations_evening_best <- sum(station_wide$evening_best)
cat(sprintf("\nStation-level check: evening is the lowest mean-emission time (averaged across all years and parameter sets) at %d of %d stations.\n",
            n_stations_evening_best, n_stations))
if (n_stations_evening_best < n_stations) {
  cat("  NOTE: evening is NOT universally optimal at every station - see station_wide for exceptions.\n")
  print(station_wide[evening_best == FALSE])
}

###############################################################################
# TABLE S1 - Probability evening best by season
###############################################################################

msg("\n[TABLE S1] Probability evening is best, by season")

table_s1_dt <- scenario_wide[season %in% inv_seasons, .(
  n_scenarios = .N,
  p_evening_best = mean(evening_is_best),
  p_eve_beats_morn = mean(evening_vs_morning > 0),
  p_eve_beats_aftn = mean(evening_vs_afternoon > 0),
  mean_adv_morn = mean(evening_vs_morning),
  mean_adv_aftn = mean(evening_vs_afternoon)
), by = season]
table_s1_dt[, season := as.character(season)]  # season is a factor (set at mc_dt creation, line ~350);
# tools::toTitleCase() requires a plain character vector, so cast before display (same fix as
# season_ens_stats above for Table 3 - this instance was missed in the original build and threw
# "'text' must be a character vector" on first run).
table_s1_dt <- table_s1_dt[match(c("spring", "summer", "autumn"), season)]

table_s1 <- data.frame(
  Season = tools::toTitleCase(table_s1_dt$season),
  `N Scenarios` = table_s1_dt$n_scenarios,
  `P(evening best)` = sprintf("%.1f%%", 100 * table_s1_dt$p_evening_best),
  `P(eve beats morn)` = sprintf("%.1f%%", 100 * table_s1_dt$p_eve_beats_morn),
  `P(eve beats aftn)` = sprintf("%.1f%%", 100 * table_s1_dt$p_eve_beats_aftn),
  `Mean adv vs morn (pp)` = sprintf("%.2f", table_s1_dt$mean_adv_morn),
  `Mean adv vs aftn (pp)` = sprintf("%.2f", table_s1_dt$mean_adv_aftn),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table_s1)
export_table(table_s1, "TableS1_probability_evening_best_by_season", tables_dir,
             notes = "Scenario-level (station x date) probabilities, aggregated across all 101 parameter sets and all slurry draws for each scenario before comparison. pp = percentage points TAN.")

###############################################################################
# TABLE 5 - Quintile characterisation of evening-advantage scenarios (3.4)
# THIS ANALYSIS DOES NOT EXIST IN ANY SOURCE SCRIPT - written fresh here.
###############################################################################

msg("\n[TABLE 5] Quintile characterisation of evening-advantage scenarios")

if (is.null(scenarios_dt)) {
  msg("SKIPPED: scenarios.csv not available, cannot compute diurnal temperature quintiles.")
} else {

  # -----------------------------------------------------------------------
  # METHOD (inferred - the manuscript Methods section does not fully spell
  # this out, so the exact procedure below is our best-supported
  # reconstruction; verify the resulting quintile boundaries/composition
  # against the manuscript's Table 5 before final submission):
  #
  # 1. Scenario-level (station x date) evening advantage, in % TAN:
  #      advantage = mean(morning_mean_ef, afternoon_mean_ef) - evening_mean_ef
  #    where each *_mean_ef is itself averaged across all parameter sets and
  #    slurry draws for that scenario (same "scenario_wide" table built
  #    above for Table S1/Section 3.3). A positive advantage means evening
  #    application reduces emissions relative to the AVERAGE of the two
  #    daytime options (not just the worse of the two, which is the metric
  #    used for the national savings estimate below) - this is a deliberate
  #    choice to keep Table 5's ranking symmetric with respect to morning
  #    vs afternoon; if your SI defines "advantage" differently (e.g. vs
  #    worst-of-two), swap the formula below.
  #
  # 2. Diurnal Range (deg C) for that scenario = max(t0_air_temp) -
  #    min(t0_air_temp) across the morning/afternoon/evening application
  #    START temperatures for that station-date, taken from scenarios.csv.
  #    LIMITATION: this is a proxy for the true daily diurnal temperature
  #    range (which would require the day's actual min/max from the full
  #    weather record, e.g. an hourly time series spanning the whole
  #    calendar day) - t0_air_temp is only sampled at the three fixed
  #    application start times (morning/afternoon/evening), so this
  #    "diurnal range" will generally UNDERESTIMATE the true daily min-max
  #    spread, especially if the true daily minimum falls overnight
  #    (outside all three application windows). Treat Table 5's "Diurnal
  #    Range" as an application-window proxy, not a meteorological diurnal
  #    range statistic.
  #
  # 3. Temperature Drop (deg C) = afternoon t0_air_temp - evening t0_air_temp
  #    for that station-date (positive = cooling into the evening, the
  #    mechanistically expected direction given lower evening ammonia loss).
  #
  # 4. Scenarios are ranked by evening advantage and split into 5 equal-n
  #    quintiles (Q1 = smallest/most negative advantage, Q5 = largest).
  # -----------------------------------------------------------------------

  scen_temp <- dcast(scenarios_dt, station + date ~ time_of_day, value.var = "t0_air_temp")
  setnames(scen_temp, c("morning", "afternoon", "evening"),
           c("temp_morning", "temp_afternoon", "temp_evening"))

  q5_dt <- merge(scenario_wide, scen_temp, by = c("station", "date"), all.x = TRUE)
  q5_dt <- q5_dt[!is.na(temp_morning) & !is.na(temp_afternoon) & !is.na(temp_evening)]

  q5_dt[, `:=`(
    evening_advantage = (morning + afternoon) / 2 - evening,
    diurnal_range = pmax(temp_morning, temp_afternoon, temp_evening) -
                    pmin(temp_morning, temp_afternoon, temp_evening),
    temp_drop = temp_afternoon - temp_evening
  )]

  n_q5 <- nrow(q5_dt)
  msg("Scenarios with matched temperature metadata for quintile analysis: ", n_q5)

  # Rank low-to-high and cut into 5 equal-sized groups (ties broken by row order)
  q5_dt <- q5_dt[order(evening_advantage)]
  q5_dt[, quintile := cut(seq_len(.N), breaks = quantile(seq_len(.N), probs = seq(0, 1, 0.2)),
                           labels = paste0("Q", 1:5), include.lowest = TRUE)]

  table5_dt <- q5_dt[, .(
    n = .N,
    mean_adv = mean(evening_advantage),
    diurnal_range = mean(diurnal_range),
    temp_drop = mean(temp_drop),
    pct_spring = 100 * mean(season == "spring"),
    pct_summer = 100 * mean(season == "summer")
  ), by = quintile][order(quintile)]

  table5 <- data.frame(
    Quintile = as.character(table5_dt$quintile),
    N = table5_dt$n,
    `Mean Delta (% TAN)` = sprintf("%.2f", table5_dt$mean_adv),
    `Diurnal Range (deg C)` = sprintf("%.2f", table5_dt$diurnal_range),
    `Temperature Drop (deg C)` = sprintf("%.2f", table5_dt$temp_drop),
    `% Spring` = sprintf("%.1f", table5_dt$pct_spring),
    `% Summer` = sprintf("%.1f", table5_dt$pct_summer),
    check.names = FALSE, stringsAsFactors = FALSE
  )
  print(table5)
  export_table(table5, "Table5_quintile_evening_advantage", tables_dir,
               notes = "Evening advantage = mean(morning, afternoon) - evening mean 168-hour cumulative %TAN, averaged over all parameter sets/slurry draws per scenario (station x date). Diurnal Range and Temperature Drop use t0_air_temp at the three fixed application start times (proxy for true daily min-max range - see code comment). Remainder of each quintile (100 - %Spring - %Summer) is Autumn.")
}

###############################################################################
# FIGURE 2 - Monthly evening advantage (bar chart, reused from 04f)
###############################################################################

msg("\n[FIGURE 2] Monthly evening advantage")

# Build the monthly summary table THIS script needs (rather than reading an
# external CSV as 04f did) - one row per (station, date) scenario with
# delta_eve_vs_morn / delta_eve_vs_aftn, then aggregated to monthly means.
scenario_wide[, month := factor(month.abb[month(date)], levels = month.abb)]
scenario_wide[, `:=`(
  delta_eve_vs_morn = morning - evening,     # positive = evening lower emission
  delta_eve_vs_aftn = afternoon - evening
)]

month_order <- month.abb[1:9]  # Jan-Sep spreading season, per manuscript figure

long_month <- rbind(
  scenario_wide[month %in% month_order, .(month, comparison = "Evening vs Morning", difference = -delta_eve_vs_morn)],
  scenario_wide[month %in% month_order, .(month, comparison = "Evening vs Afternoon", difference = -delta_eve_vs_aftn)]
)
plot_stats <- long_month[, .(
  mean_diff = mean(difference, na.rm = TRUE),
  sd_diff = sd(difference, na.rm = TRUE),
  n = .N
), by = .(month, comparison)]
plot_stats[, se_diff := sd_diff / sqrt(n)]
plot_stats[, `:=`(ci_lower = mean_diff - 1.96 * se_diff, ci_upper = mean_diff + 1.96 * se_diff)]
plot_stats[, month := factor(month, levels = month_order)]
plot_stats[, comparison := factor(comparison, levels = c("Evening vs Morning", "Evening vs Afternoon"))]

export_table(as.data.frame(plot_stats) |> transform(month = as.character(month)),
             "SuppTable_monthly_evening_advantage", tables_dir,
             notes = "Difference = signed change in 168-hour cumulative %TAN emission relative to evening application (negative = evening lower emission), averaged across scenarios within each month across Jan-Sep spreading season; error bars in Figure 2 are 95% CI.")

fig2 <- ggplot(plot_stats, aes(x = month, y = mean_diff, fill = comparison)) +
  geom_hline(yintercept = 0, linetype = "solid", color = "grey50", linewidth = 0.5) +
  geom_col(position = position_dodge(width = 0.8), width = 0.7, color = "black", linewidth = 0.2) +
  geom_errorbar(aes(ymin = ci_lower, ymax = ci_upper),
                position = position_dodge(width = 0.8), width = 0.3, linewidth = 0.4) +
  scale_fill_manual(values = c("Evening vs Morning" = color_vs_morning,
                                "Evening vs Afternoon" = color_vs_afternoon), name = "") +
  labs(x = "Month", y = "Emission Difference (% TAN)") +
  theme_pub()

ggsave(file.path(figures_dir, "Figure2_monthly_evening_advantage.png"), fig2,
       width = fig_width_in, height = fig_height_in, dpi = FIG_DPI, bg = "white")
msg("Saved Figure 2: monthly evening advantage (300 dpi, 170mm wide)")

###############################################################################
# TABLE S2 - Annual summary statistics
###############################################################################

msg("\n[TABLE S2] Annual summary statistics")

# Annual mean/SD of emission fraction: aggregate across all parameter sets
# and slurry draws within each year (national, station-pooled).
annual_ef <- mc_dt[, .(
  mean_ef = mean(emission_frac, na.rm = TRUE),
  sd_ef = sd(emission_frac, na.rm = TRUE)
), by = year]

# Annual mean temperature: mc_results_master.csv carries temp0 (=temp_t0),
# the application-start-time temperature for each simulation row, which
# IS available at the same annual grain as emission_frac, so we use it
# directly rather than needing a separate weather file. This is the only
# temperature proxy available at this stage of the pipeline (see
# limitation noted below) - a true annual mean air temperature would need
# the full continuous daily weather record, which is upstream of the
# scenario-selection step and not carried into mc_results_master.csv.
annual_temp <- mc_dt[, .(mean_temp = mean(temp0, na.rm = TRUE)), by = year]

# Annual evening advantage: scenario-level (station x date), i.e. reuse
# scenario_wide (already aggregated across all parameter sets/draws),
# grouped by the calendar year of the application date.
scenario_wide[, app_year := year(date)]
annual_adv <- scenario_wide[, .(
  eve_advantage = mean(pmax(morning, afternoon) - evening, na.rm = TRUE)
), by = .(year = app_year)]

annual_summary <- merge(annual_ef, annual_temp, by = "year")
annual_summary <- merge(annual_summary, annual_adv, by = "year", all.x = TRUE)
annual_summary <- annual_summary[order(year)]

table_s2 <- data.frame(
  Year = annual_summary$year,
  `Mean EF (% TAN)` = sprintf("%.2f", annual_summary$mean_ef),
  `SD (pp)` = sprintf("%.2f", annual_summary$sd_ef),
  `Mean Temp (deg C)` = sprintf("%.1f", annual_summary$mean_temp),
  `Evening Adv (pp)` = sprintf("%.2f", annual_summary$eve_advantage),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table_s2)
export_table(table_s2, "TableS2_annual_summary", tables_dir,
             notes = "Mean EF and SD: 168-hour cumulative %TAN emission, aggregated (mean/SD) across all parameter sets and slurry draws within each calendar year, station-pooled to national scale. Mean Temp: mean application-start-time air temperature (temp_t0) across all scenarios that year - a proxy for annual mean temperature, not a full-year climatological mean (see code comment). Evening Adv: mean scenario-level evening advantage vs the worse of morning/afternoon.")

###############################################################################
# SECTION 3.5 (annual trends) / FIGURE 3 / TABLE 6 (climate projections)
###############################################################################

msg("\n[SECTION 3.5] Annual trend statistics and climate projection")

lm_trend_ef <- lm(mean_ef ~ year, data = annual_summary)
slope_ef_year <- coef(lm_trend_ef)["year"]
p_ef_year <- summary(lm_trend_ef)$coefficients["year", "Pr(>|t|)"]
r2_ef_year <- summary(lm_trend_ef)$r.squared

lm_trend_adv <- lm(eve_advantage ~ year, data = annual_summary)
slope_adv_year <- coef(lm_trend_adv)["year"]
p_adv_year <- summary(lm_trend_adv)$coefficients["year", "Pr(>|t|)"]
r2_adv_year <- summary(lm_trend_adv)$r.squared

cat(sprintf("\nAnnual emission trend: %.4f %%TAN/year (%.2f %%TAN/decade), R2 = %.2f, p = %.3f\n",
            slope_ef_year, slope_ef_year * 10, r2_ef_year, p_ef_year))
cat(sprintf("Annual evening-advantage trend: %.5f pp/year, R2 = %.2f, p = %.3f\n",
            slope_adv_year, r2_adv_year, p_adv_year))

# ---- FIGURE 3: annual trend, dual axis (reused near-verbatim from 04f) -------
scale_factor <- 2.5
offset <- 8.5

fig3 <- ggplot(annual_summary, aes(x = year)) +
  geom_ribbon(aes(ymin = mean_ef - sd_ef, ymax = mean_ef + sd_ef), alpha = 0.15, fill = color_emissions) +
  geom_smooth(aes(y = mean_ef), method = "lm", se = FALSE, linetype = "dashed", color = color_emissions, linewidth = 0.8) +
  geom_point(aes(y = mean_ef), color = color_emissions, size = 3, shape = 16) +
  geom_smooth(aes(y = eve_advantage * scale_factor + offset), method = "lm", se = FALSE,
              linetype = "dashed", color = color_advantage, linewidth = 0.8) +
  geom_point(aes(y = eve_advantage * scale_factor + offset), color = color_advantage, size = 3, shape = 17) +
  scale_x_continuous(breaks = pretty(annual_summary$year)) +
  scale_y_continuous(
    name = "Mean Emission Fraction (% TAN)",
    sec.axis = sec_axis(~ (. - offset) / scale_factor, name = "Evening Advantage (pp TAN)")
  ) +
  labs(x = "Year") +
  theme_pub() +
  theme(axis.title.y.left = element_text(color = "black"), axis.title.y.right = element_text(color = "black"))

ggsave(file.path(figures_dir, "Figure3_annual_trend_dual_axis.png"), fig3,
       width = fig_width_in, height = fig_height_in, dpi = FIG_DPI, bg = "white")
msg("Saved Figure 3: annual trend dual-axis (300 dpi, 170mm wide)")

# ---- TABLE 6: climate warming projection ---------------------------------
# APPROACH (documented limitation): rather than re-running ALFAM2 under
# perturbed future weather, we fit a simple linear regression of the
# ANNUAL summary values (Table S2) on annual mean temperature - i.e. a
# space-for-time / interannual-variability substitution - and use its
# slope as an empirical temperature sensitivity, then project forward
# using the stated CLIMATE_TEMP_CHANGE_C increments. This is explicitly a
# SIMPLE LINEAR EXTRAPOLATION and does NOT capture non-linear ALFAM2
# response, changes in rainfall/wind under future climate, changes in
# farmer spreading behaviour, or the closed-period calendar shifting with
# climate. Flagged here per the manuscript's own stated limitation.
lm_ef_vs_temp  <- lm(mean_ef ~ mean_temp, data = annual_summary)
lm_adv_vs_temp <- lm(eve_advantage ~ mean_temp, data = annual_summary)

sens_ef_temp  <- coef(lm_ef_vs_temp)["mean_temp"]     # %TAN per degC
sens_adv_temp <- coef(lm_adv_vs_temp)["mean_temp"]    # pp per degC

cat(sprintf("\nEmpirical temperature sensitivity: %.4f %%TAN/degC (target ~0.233)\n", sens_ef_temp))
cat(sprintf("Empirical evening-advantage temperature sensitivity: %.4f pp/degC (target ~0.0613)\n", sens_adv_temp))

baseline_ef  <- mean(annual_summary$mean_ef)         # "Current" baseline = mean over the simulated period
baseline_adv <- mean(annual_summary$eve_advantage, na.rm = TRUE)

table6_dt <- data.table(
  Period = CLIMATE_PERIODS,
  temp_change = CLIMATE_TEMP_CHANGE_C
)
table6_dt[, `:=`(
  mean_ef = baseline_ef + sens_ef_temp * temp_change,
  eve_adv = baseline_adv + sens_adv_temp * temp_change
)]
table6_dt[, adv_increase_pct := 100 * (eve_adv - baseline_adv) / baseline_adv]

table6 <- data.frame(
  Period = table6_dt$Period,
  `Temp Change (deg C)` = sprintf("%.2f", table6_dt$temp_change),
  `Mean EF (% TAN)` = sprintf("%.2f", table6_dt$mean_ef),
  `Evening Adv (% TAN)` = sprintf("%.2f", table6_dt$eve_adv),
  `Adv Increase (%)` = sprintf("%.1f", table6_dt$adv_increase_pct),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table6)
export_table(table6, "Table6_climate_projection", tables_dir,
             notes = "Projections are SIMPLE LINEAR EXTRAPOLATIONS from the empirical relationship between annual mean emission/evening advantage and annual mean application-time temperature within the simulated (2013-2025) period - they do not represent a re-simulation of ALFAM2 under future climate weather. Temp Change values are illustrative mid-century warming increments (deg C above baseline).")

###############################################################################
# NATIONAL-SCALE SAVINGS ESTIMATE (Section 4.6)
###############################################################################

msg("\n[NATIONAL SAVINGS] National-scale emission savings estimate")

# Mean reduction achievable by switching to evening spreading, expressed as
# a fraction of total emissions, computed from the FULL ensemble at
# scenario level (station x date), vs the WORSE of morning/afternoon (i.e.
# the counterfactual practice being displaced).
mean_reduction_vs_worst <- mean(pmax(scenario_wide$morning, scenario_wide$afternoon) - scenario_wide$evening, na.rm = TRUE)
mean_ef_overall <- mean(mc_dt$emission_frac, na.rm = TRUE)
pct_reduction_computed <- 100 * mean_reduction_vs_worst / mean_ef_overall

national_saving_kt_computed <- NATIONAL_NH3_FIELD_APPLICATION_KT * (pct_reduction_computed / 100)

cat(sprintf("\nMean scenario-level reduction from evening application: %.2f pp\n", mean_reduction_vs_worst))
cat(sprintf("As %% of overall mean emission: %.1f%% (manuscript-stated: %.1f%%)\n",
            pct_reduction_computed, MANUSCRIPT_REDUCTION_PCT))
cat(sprintf("National saving estimate (computed): %.2f kt NH3/yr (manuscript-stated: ~%.1f kt/yr)\n",
            national_saving_kt_computed, MANUSCRIPT_SAVING_KT_CURRENT))

national_savings_table <- data.frame(
  Metric = c("National NH3 from field-applied manure (kt/yr, 2024)",
             "Field application as % of national NH3 total",
             "Computed relative reduction from evening shift (%)",
             "Manuscript-stated relative reduction (%)",
             "Computed national saving (kt NH3/yr)",
             "Manuscript-stated national saving, current (kt NH3/yr)",
             "Manuscript-stated national saving, ~2050 (kt NH3/yr)"),
  Value = c(sprintf("%.2f", NATIONAL_NH3_FIELD_APPLICATION_KT),
            sprintf("%.1f", NATIONAL_NH3_FIELD_APPLICATION_PCT_TOT),
            sprintf("%.1f", pct_reduction_computed),
            sprintf("%.1f", MANUSCRIPT_REDUCTION_PCT),
            sprintf("%.2f", national_saving_kt_computed),
            sprintf("%.1f", MANUSCRIPT_SAVING_KT_CURRENT),
            sprintf("%.1f", MANUSCRIPT_SAVING_KT_2050)),
  stringsAsFactors = FALSE
)
print(national_savings_table)
export_table(national_savings_table, "Table_national_savings_estimate", tables_dir,
             notes = "National-scale (whole-of-Ireland) estimate. The ~2050 figure is a manuscript-stated reference value based on assumed herd-growth trajectories that are outside the scope of the ALFAM2 Monte Carlo dataset and are therefore reported, not re-derived, here.")

###############################################################################
# SECTION 3.6 - Variance decomposition (Type I / sequential ANOVA)
###############################################################################

msg("\n[SECTION 3.6] Variance decomposition (Type I ANOVA)")

# Sequential (Type I) ANOVA: factor order matters for a Type I decomposition
# because each factor's sum of squares is computed AFTER accounting for the
# factors already in the model. Order chosen to match the manuscript's
# reported hierarchy (temperature first, as the dominant physicochemical
# driver of ammonia volatilisation, down to station last, as a
# spatial/residual grouping factor). Using the CENTRAL parameter set here
# avoids conflating parameter-set uncertainty with the weather/management
# variance being decomposed (the ensemble spread across 101 parameter sets
# is already characterised separately in Table 2).
mc_central <- mc_dt[param_set_id == CENTRAL_PS]
if (!("wind0" %in% names(mc_central))) {
  msg("WARNING: wind0/wind_t0 not found in mc_results_master.csv - wind speed factor omitted from variance decomposition.")
  lm_decomp <- lm(emission_frac ~ temp0 + season + time_of_day + station, data = mc_central)
} else {
  lm_decomp <- lm(emission_frac ~ temp0 + wind0 + season + time_of_day + station, data = mc_central)
}
anova_decomp <- anova(lm_decomp)
total_ss <- sum(anova_decomp[, "Sum Sq"])

var_decomp <- data.table(
  Factor = rownames(anova_decomp),
  SS = anova_decomp[, "Sum Sq"],
  DF = anova_decomp[, "Df"],
  Fval = anova_decomp[, "F value"],
  p_value = anova_decomp[, "Pr(>F)"]
)
var_decomp[, pct_variance := 100 * SS / total_ss]
print(var_decomp[, .(Factor, pct_variance = round(pct_variance, 2))])

label_map <- c(temp0 = "Air temperature", wind0 = "Wind speed", season = "Season",
               time_of_day = "Time of day", station = "Station", Residuals = "Residual")
var_decomp[, Factor_label := ifelse(Factor %in% names(label_map), label_map[Factor], Factor)]

table_variance <- data.frame(
  Factor = var_decomp$Factor_label,
  `Sum of Squares` = formatC(var_decomp$SS, format = "f", digits = 0, big.mark = ","),
  `% Variance` = sprintf("%.2f%%", var_decomp$pct_variance),
  `F` = ifelse(is.na(var_decomp$Fval), "-", sprintf("%.1f", var_decomp$Fval)),
  `p-value` = ifelse(is.na(var_decomp$p_value), "-", ifelse(var_decomp$p_value < 0.001, "< 0.001", sprintf("%.3f", var_decomp$p_value))),
  check.names = FALSE, stringsAsFactors = FALSE
)
print(table_variance)
export_table(table_variance, "TableS_variance_decomposition", tables_dir,
             notes = "Sequential (Type I) ANOVA on the central ALFAM2 parameter set only, factor order: temperature, wind speed, season, time of day, station. % Variance = eta-squared (SS_factor / SS_total).")

###############################################################################
# TABLE S3 - Nitrates Action Programme spreading calendar (static)
###############################################################################

msg("\n[TABLE S3] Nitrates Action Programme closed/open spreading periods")
print(table_s3_nap)
export_table(table_s3_nap, "TableS3_NAP_spreading_calendar", tables_dir,
             notes = "Source: S.I. No. 113 of 2022. NOTE: Leitrim, Cavan and Monaghan appear in both Zone A and Zone C as transcribed in the manuscript - verify against the statutory instrument before final submission (see code comment near table_s3_nap in this script).")

###############################################################################
# FINAL SUMMARY
###############################################################################

msg("\n", paste(rep("=", 78), collapse = ""))
msg("[SUMMARY] 04_simulation_analysis.R complete")
msg(paste(rep("=", 78), collapse = ""))

cat(sprintf("
================================================================================
OUTPUTS GENERATED
================================================================================
Tables (csv + docx) written to: %s
  Table1_slurry_property_distributions
  Table2_parameter_set_characterisation
  Table3_inventory_comparison
  Table4_emission_by_timeofday_season
  TableS1_probability_evening_best_by_season
  Table5_quintile_evening_advantage (if scenarios.csv available)
  SuppTable_evening_advantage_by_parameter_set
  SuppTable_monthly_evening_advantage
  TableS2_annual_summary
  Table6_climate_projection
  Table_national_savings_estimate
  TableS_variance_decomposition
  TableS3_NAP_spreading_calendar

Figures (300 dpi, 170mm wide) written to: %s
  Figure2_monthly_evening_advantage.png
  Figure3_annual_trend_dual_axis.png
================================================================================
", tables_dir, figures_dir
))

msg("Central parameter set used: ", CENTRAL_PS)
msg("Done.")
