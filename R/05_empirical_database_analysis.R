# =============================================================================
# ALFAM2 Empirical Database Analysis: Time-of-Day and Early/Late Period Effects
# =============================================================================
#
# PURPOSE:
#   Single, harmonised script reproducing the empirical-database-derived
#   results in the manuscript:
#
#     Section 2.7.1 / 3.5.1 - Time-of-day analysis
#       Analysis A: all surface application methods
#       Analysis B: trailing shoe only
#       -> Table 7 (raw category means), mixed-effects models, sensitivity
#          analysis restricted to micrometeorological measurement methods
#
#     Section 2.7.2 / 3.5.2 - Early (0-6h) versus late (6-24h) period
#       weather analysis
#       -> Table S4 (mixed-effects coefficients, full sample vs strict
#          subset), Figure 4 (coefficient plot, full sample)
#
#   The ALFAM2 database is loaded and cleaned ONCE (Sections 1-3 below);
#   both analyses then branch from the shared cleaned plot-level table
#   (`pdat_clean`), with any analysis-specific filtering kept explicit and
#   commented at the point where it diverges.
#
# EMISSION VARIABLE:
#   e.rel.final (or e.rel): cumulative NH3 emission at the final measurement
#   interval, expressed as a fraction of applied TAN (0-1 scale). Converted
#   to % TAN (x100) for all outputs. This is CUMULATIVE and PLOT-LEVEL data
#   (one value per field plot, not an instantaneous rate, not spatially
#   averaged across plots).
#
# DATA SOURCE:
#   ALFAM2 database (Hafner et al.), plot-level and interval-level files,
#   https://github.com/AU-BCE-EE/ALFAM2-data
#
# =============================================================================

# ===================== USER SETTINGS ========================================
# Everything you are likely to need to change to re-run this script on an
# updated database, or to adjust a filter/definition, is collected here.

# --- ALFAM2 database version and download ---
# You do NOT need to manually download the ALFAM2 files - this script
# fetches them automatically from GitHub the first time it runs, and caches
# them locally at `plot_data_path`/`interval_data_path` below so subsequent
# runs are fast and don't re-download.
#
# WHICH VERSION: ALFAM2-data (https://github.com/AU-BCE-EE/ALFAM2-data) is a
# LIVE, actively-updated repository - institutions add and revise plot
# submissions over time, so results can shift slightly between downloads
# taken months apart. This script pins an explicit release tag (rather than
# the `master` branch, which always means "whatever is newest right now")
# so that a given run is reproducible.
#
# There are two independent identifiers to pin: the release TAG (e.g.
# "v3.0") and the SUBMISSION PERIOD (a data-organisation concept specific to
# ALFAM2-data, currently "01" through "04"). Per the ALFAM2-data repository's
# own documentation, submission periods group the database's build history:
# period 4 is the current, actively-maintained effort, and "the latest
# version will always be in the highest submission period number." Earlier
# submission periods are retained as frozen historical snapshots and are not
# updated further. This script uses the current tag together with the
# current submission period, i.e. the dataset the maintainers themselves
# point users to as authoritative.
ALFAM2_VERSION_TAG <- "v3.0"
ALFAM2_SUBMISSION_PERIOD <- "04"

# Constructed automatically from the settings above. If ALFAM2-data
# restructures its repository layout in the future, re-check this pattern
# against https://github.com/AU-BCE-EE/ALFAM2-data/tree/master/data-output.
ALFAM2_BASE_URL <- paste0("https://raw.githubusercontent.com/AU-BCE-EE/ALFAM2-data/",
                           ALFAM2_VERSION_TAG, "/data-output/", ALFAM2_SUBMISSION_PERIOD, "/")

# Local cache paths - downloaded files are saved here on first run and
# reused on subsequent runs without re-downloading. The path is tagged with
# both the version and submission period (e.g. data/ALFAM2/v3.0_04/...) so
# that changing either setting above automatically triggers a fresh
# download instead of silently reusing a cached file from a different
# version/period combination.
plot_data_path     <- file.path("data", "ALFAM2", paste0(ALFAM2_VERSION_TAG, "_", ALFAM2_SUBMISSION_PERIOD), "ALFAM2_plot.csv.gz")
interval_data_path <- file.path("data", "ALFAM2", paste0(ALFAM2_VERSION_TAG, "_", ALFAM2_SUBMISSION_PERIOD), "ALFAM2_interval.csv.gz")

# Set to FALSE to require a pre-placed local file and never attempt a
# network download (e.g. on an offline machine, or if you specifically want
# to guarantee no accidental re-download of a different version).
ALFAM2_ALLOW_DOWNLOAD <- TRUE

# --- Output locations ---
output_dir  <- file.path("output", "05_empirical_analysis")
table_dir   <- file.path(output_dir, "tables")
figure_dir  <- file.path(output_dir, "figures")

# Label used in table captions/notes to identify the database version.
# Includes the submission period alongside the tag (they're independent
# axes - see the comment above) so a reader of the manuscript's table
# captions can trace the exact data source, not just the tag.
ALFAM2_VERSION_LABEL <- paste0(ALFAM2_VERSION_TAG, ", submission period ", ALFAM2_SUBMISSION_PERIOD)

# --- Time-of-day category boundaries (24-h clock, decimal hours) ---
# Manuscript Section 2.6.1 states the category definitions in "H.MM" clock
# notation, not decimal hours: "morning (start hour 5.00 to 11.50), afternoon
# (11.50 to 16.50), and evening (16.50 to 21.00)". The boundary values use
# CLOCK-TIME notation (11.50 = 11:50, 16.50 = 16:50), not decimal hours
# (which would put 11.50 at 11:30) - set accordingly below. If a future
# manuscript revision states the boundaries unambiguously
# (e.g. "11:50" or "11.83"), update this comment but the values should
# already be correct.
MORNING_START   <- 5.0;               MORNING_END   <- 11 + 50/60   # 05:00 - 11:49
AFTERNOON_START <- 11 + 50/60;        AFTERNOON_END <- 16 + 50/60   # 11:50 - 16:49
EVENING_START   <- 16 + 50/60;        EVENING_END   <- 21.0         # 16:50 - 20:59

# --- Injection method codes to exclude from BOTH analyses ---
# Open slot ("os") and closed slot ("cs") injection place slurry below the
# surface, bypassing the soil-surface volatilisation pathway that the
# time-of-day / early-late mechanisms rely on. Both short ALFAM2 codes and
# plausible full-word variants are listed; the script also prints all
# unique application-method values it finds so you can extend this list if
# the database uses an unlisted code.
INJECTION_ABBREVIATIONS <- c("os", "osi", "cs", "csi", "si",
                              "open slot", "openslot", "closed slot", "closedslot",
                              "open slot injection", "closed slot injection",
                              "slot injection", "injection")

# --- Trailing shoe method codes (defines Analysis B / the strict subset) ---
TRAILING_SHOE_CODES <- c("ts", "trailing shoe", "trailingshoe", "narrow band",
                          "narrowband", "band application")

# --- Shared emission-range filter (plots outside this range are treated as
# recording errors and excluded from BOTH analyses) ---
# 0-105% TAN, per the manuscript's stated exclusion criterion for both the
# time-of-day analysis and the early/late analysis. (An earlier internal
# draft of the time-of-day script used a looser 0-130% cutoff; the 105%
# cutoff below is used throughout this script for internal consistency
# with the manuscript text and with the early/late analysis.)
MIN_EMISSION_FRAC <- 0.0
MAX_EMISSION_FRAC <- 1.05

# --- Early / late period definitions (hours after application) ---
EARLY_PERIOD_START <- 0;  EARLY_PERIOD_END <- 6     # 0-6 h
LATE_PERIOD_START  <- 6;  LATE_PERIOD_END  <- 24     # 6-24 h (exclusive of 6)
MIN_OBS_PER_PERIOD <- 1   # minimum interval-level weather obs required per period

# --- Strict subset settings (manuscript Section 2.7.2, Table S4) ---
# The manuscript's prose enumerates this subset as "unacidified cattle
# slurry with DM > 2%" and separately describes it as "representing
# conditions approximating Irish trailing-shoe practice" - which reads as
# ambiguous about whether application method is an actual filter criterion
# or just contextual framing. This was tested both ways against the n = 188
# (7 institutions) target reported in the manuscript:
#   - WITHOUT a trailing-shoe filter: n = 751 (~4x too many) - the man_source/
#     acid/DM filters alone are nowhere near restrictive enough to reach 188.
#   - WITH a trailing-shoe filter (STRICT_APP_METHODS below), applied BEFORE
#     the cattle/acid/DM filters: much closer to 188 (order-of-magnitude
#     consistent, given ~15% of the eligible pool is trailing-shoe and the
#     remaining filters retain roughly that same proportion as they do on the
#     full sample).
# Conclusion: application method IS a real filter criterion for this subset,
# despite not being explicitly listed in the enumerated criteria sentence -
# "approximating Irish trailing-shoe practice" is describing an actual
# restriction, not just motivation. Restored below. (An even earlier version
# of this script had this filter AND the Part-II injection-exclusion bug at
# the same time, which combined to produce n = 113 - don't mistake that old
# number for evidence against this filter; it was confounded by the other,
# separate bug that has since been fixed - see the injection-exclusion
# comment further down.)
STRICT_APP_METHODS  <- c("ts")    # Trailing shoe only, per the reasoning above
STRICT_MAN_SOURCE   <- c("cat")   # ALFAM2 distributed man.source code for cattle
STRICT_MIN_PH       <- 6.5        # exclude acidified slurry (pH <= 6.5)
STRICT_MIN_DM       <- 2.0        # exclude severely separated slurry (DM <= 2%)

# --- Measurement-method classification (for the micrometeorological
# sensitivity analysis in Section 3.5.1) ---
# AMBIGUITY, stated explicitly: neither the ALFAM2 plot-file documentation
# consulted for this script nor the source scripts it replaces (04d/04e)
# specify one canonical column name or coding scheme for measurement
# technique. The ALFAM2 database description confirms such a column exists
# and records values including a broad "micrometeorological" category, more
# specific method codes (e.g. IHF, ZINST) for a few institutes, and
# enclosure-based methods (wind tunnel, dynamic/static chamber). No
# authoritative value list was available at the time this script was
# written. DEFAULT CHOICE: search for a column matching the patterns below;
# print every unique value found (as already done for method/manure) so you
# can verify/extend the keyword lists; classify any value containing one of
# CHAMBER_METHOD_KEYWORDS (case-insensitive, substring match) as chamber
# (enclosure)-based, and everything else (non-missing) as
# micrometeorological. If no matching column is found at all, the
# sensitivity analysis is skipped with an explanatory message rather than
# erroring - check this against the printed diagnostic output before
# trusting the sensitivity-analysis numbers.
MEAS_METHOD_COL_PATTERNS <- c("^e\\.meth$", "^e\\.tech$", "^meth\\.meas$",
                               "^meas\\.meth", "^meas\\.tech", "^method\\.meas$",
                               "^emiss?\\.meth", "^tech$")
CHAMBER_METHOD_KEYWORDS  <- c("cham", "hood", "tunnel", "\\bwt\\b")

# --- Figure settings ---
PLOT_DPI <- 300
# Dimensions follow the project's Figure Style Specification: double-column
# figures are 170 mm (6.7 in) wide, height ~60-80% of width.
FIG_WIDTH_DOUBLE  <- 6.7
FIG_HEIGHT_DOUBLE <- 4.7
FIG_WIDTH_SINGLE  <- 3.15
FIG_HEIGHT_SINGLE <- 3.4

# Colour-blind friendly palette, per the project's Figure Style Specification
TOD_COLOURS <- c("Morning" = "#E69F00", "Afternoon" = "#56B4E9", "Evening" = "#009E73")

# --- Misc ---
SEED     <- 42
CI_LEVEL <- 0.95

# =============================================================================
# End of USER SETTINGS - the remainder of the script should not normally
# need editing.
# =============================================================================

library(data.table)
library(lubridate)  # parse_date_time() - robust multi-format datetime parsing for t.start.p
library(ggplot2)
library(lme4)
library(lmerTest)   # Satterthwaite p-values for lmer summaries
library(MuMIn)      # marginal/conditional R2 for mixed models
library(flextable)
library(officer)

set.seed(SEED)
for (d in c(output_dir, table_dir, figure_dir)) if (!dir.exists(d)) dir.create(d, recursive = TRUE)

msg <- function(...) cat("[", format(Sys.time(), "%H:%M:%S"), "] ", ..., "\n", sep = "")

# -----------------------------------------------------------------------------
# Generic helpers reused across both analyses
# -----------------------------------------------------------------------------

# Robustly find a column by trying several regex patterns in turn (ALFAM2
# column names have varied slightly across database releases).
find_col <- function(patterns, col_names, label, required = TRUE) {
  for (p in patterns) {
    hit <- grep(p, col_names, value = TRUE, ignore.case = TRUE, perl = TRUE)
    if (length(hit) > 0) return(hit[1])
  }
  if (required) warning("Column not found for: ", label)
  NA_character_
}

# Format a decimal hour (e.g. 10.4) as a 24-h "HH:MM" string, matching the
# manuscript's Table 7 formatting (e.g. "10:24").
format_hour_hm <- function(x) {
  total_min <- round(x * 60)
  h <- (total_min %/% 60) %% 24
  m <- total_min %% 60
  sprintf("%02d:%02d", h, m)
}

# p-value formatter used in tables (three decimals, "< 0.001" below that)
fmt_p <- function(p) {
  ifelse(is.na(p), NA_character_,
         ifelse(p < 0.001, "< 0.001", sprintf("%.3f", p)))
}

# Apply the project's Table Formatting Specification to a flextable object:
# three-line table (top/header-body/bottom borders only, no vertical lines),
# bold header, Times New Roman 10pt, numbers centred (text columns are
# re-aligned left by the caller via `left_cols`).
style_flextable <- function(ft, caption_text, left_cols = NULL) {
  ft <- ft |>
    autofit() |>
    bold(part = "header") |>
    align(align = "center", part = "all") |>
    fontsize(size = 10, part = "all") |>
    font(fontname = "Times New Roman", part = "all") |>
    border_remove() |>
    hline_top(part = "header", border = fp_border(width = 1.5)) |>
    hline_bottom(part = "header", border = fp_border(width = 1.0)) |>
    hline_bottom(part = "body", border = fp_border(width = 1.5)) |>
    set_caption(caption = caption_text)
  if (!is.null(left_cols)) ft <- ft |> align(j = left_cols, align = "left", part = "all")
  ft
}

# Export a display-ready data.frame/data.table as both CSV (for
# plotting/statistical re-use) and a Word-exportable flextable .docx
# (matching house style), in one call, to avoid duplicating this logic for
# every table produced below.
export_table <- function(dt_display, out_stub, caption_text, notes_text = NULL, left_cols = NULL) {
  fwrite(dt_display, paste0(out_stub, ".csv"))
  ft  <- flextable(as.data.frame(dt_display))
  ft  <- style_flextable(ft, caption_text, left_cols = left_cols)
  doc <- read_docx()
  doc <- body_add_flextable(doc, ft)
  if (!is.null(notes_text)) {
    doc <- body_add_par(doc, "")
    doc <- body_add_par(doc, notes_text, style = "Normal")
  }
  print(doc, target = paste0(out_stub, ".docx"))
  msg("  Saved table: ", basename(out_stub), ".csv / .docx")
}

save_figure <- function(p, filename, width, height) {
  ggsave(file.path(figure_dir, filename), p, width = width, height = height,
         dpi = PLOT_DPI, bg = "white")
  msg("  Saved figure: ", filename)
}

# Extract Estimate / SE / p for one fixed-effect term from a fitted model
# (works for both lmerTest models and lm fallbacks). Returns NA fields
# (rather than erroring) if the term is absent - e.g. because a category
# had zero rows in a filtered subset and was dropped from the factor.
get_term_stat <- function(mod, term) {
  cs <- tryCatch(coef(summary(mod)), error = function(e) NULL)
  if (is.null(cs) || !(term %in% rownames(cs))) {
    return(list(est = NA_real_, se = NA_real_, p = NA_real_))
  }
  p_col <- intersect(c("Pr(>|t|)", "Pr(>|z|)"), colnames(cs))[1]
  list(est = unname(cs[term, "Estimate"]),
       se  = unname(cs[term, "Std. Error"]),
       p   = if (!is.na(p_col)) unname(cs[term, p_col]) else NA_real_)
}

# =============================================================================
# SECTION 1: LOAD DATA ONCE
# =============================================================================

# Downloads on first run and caches to `local_path` so every subsequent run
# reads the local copy instead of re-downloading (fast, works offline once
# cached, and means the exact bytes used are sitting on disk for provenance -
# you can check them into your own records or hash them if you want to prove
# later exactly what went into a given set of results). Set
# ALFAM2_ALLOW_DOWNLOAD <- FALSE above to disable downloading entirely and
# require a pre-placed local file (e.g. on an offline/air-gapped machine).
load_alfam2_file <- function(local_path, filename) {
  if (file.exists(local_path)) {
    msg("Loading cached local file: ", local_path)
    return(fread(local_path))
  }
  if (!ALFAM2_ALLOW_DOWNLOAD) {
    stop("File not found and downloading disabled (ALFAM2_ALLOW_DOWNLOAD = FALSE): ", local_path)
  }
  url <- paste0(ALFAM2_BASE_URL, filename)
  msg("No local cache found - downloading from ", url)
  dir.create(dirname(local_path), recursive = TRUE, showWarnings = FALSE)
  tryCatch(
    {
      download.file(url, destfile = local_path, mode = "wb", quiet = TRUE)
      msg("  Downloaded and cached to: ", local_path)
    },
    error = function(e) stop(
      "Could not download ", filename, " from ", url, " (", conditionMessage(e), "). ",
      "Check ALFAM2_VERSION_TAG is a real tag at https://github.com/AU-BCE-EE/ALFAM2-data/tags, ",
      "check your internet connection, or manually download the file and place it at:\n  ",
      local_path
    )
  )
  fread(local_path)
}

msg("Loading ALFAM2 plot-level and interval-level data (once, shared by both analyses)...")
pdat <- load_alfam2_file(plot_data_path, "ALFAM2_plot.csv.gz")
idat <- load_alfam2_file(interval_data_path, "ALFAM2_interval.csv.gz")
msg("  Plot-level:     ", format(nrow(pdat), big.mark = ","), " rows, ", ncol(pdat), " columns")
msg("  Interval-level: ", format(nrow(idat), big.mark = ","), " rows, ", ncol(idat), " columns")

# =============================================================================
# SECTION 2: IDENTIFY AND STANDARDISE COLUMN NAMES (once)
# =============================================================================
# ALFAM2 column names vary slightly between database releases. We resolve
# them once here and rename to short canonical names, so every downstream
# section can refer to (e.g.) `app_method` rather than repeating
# `get(col_app)` throughout, as the two source scripts each did separately.

cn_p <- names(pdat)
cn_i <- names(idat)

col_pmid_p  <- find_col(c("^pmid$", "^plot\\.id$", "^plotid$"), cn_p, "plot ID (plot-level)")
col_app     <- find_col(c("^app\\.method$", "^app\\.meth$", "^appl\\.method", "^method$"), cn_p, "application method")
col_manure  <- find_col(c("^man\\.source$", "^man\\.type$", "^slurry\\.type", "^manure\\.type$"), cn_p, "manure source")
col_inst    <- find_col(c("^inst$", "^institution$", "^institute$"), cn_p, "institution")
col_emis    <- if ("e.rel.final" %in% cn_p) "e.rel.final" else
               if ("e.rel" %in% cn_p) "e.rel" else find_col(c("e\\.rel"), cn_p, "emission")
col_dm      <- find_col(c("^man\\.dm$", "^dm$", "^dry\\.matter$"), cn_p, "dry matter")
col_ph      <- find_col(c("^man\\.ph$", "^slurry\\.ph$", "^ph$"), cn_p, "slurry pH", required = FALSE)
col_acid    <- find_col(c("^acid$", "^acidified$", "^acidification$"), cn_p, "acidification flag", required = FALSE)
col_meas    <- find_col(MEAS_METHOD_COL_PATTERNS, cn_p, "measurement method/technique", required = FALSE)

col_pmid_i  <- find_col(c("^pmid$", "^plot\\.id$", "^plotid$"), cn_i, "plot ID (interval-level)")
col_ct      <- find_col(c("^ct$", "^cum\\.time$", "^ctime$", "^t\\.cum$"), cn_i, "cumulative time since application")
col_air     <- find_col(c("^air\\.temp\\.24$", "^air\\.temp$", "^t\\.air$", "^temp$"), cn_i, "air temperature")
col_wind    <- find_col(c("^wind\\.2m\\.24$", "^wind\\.2m$", "^wind$", "^ws$"), cn_i, "wind speed")

msg("Column mapping:")
cat("  [plot]     pmid        : ", ifelse(is.na(col_pmid_p), "NOT FOUND", col_pmid_p), "\n")
cat("  [plot]     app.method  : ", ifelse(is.na(col_app),    "NOT FOUND", col_app),    "\n")
cat("  [plot]     man.source  : ", ifelse(is.na(col_manure), "NOT FOUND", col_manure), "\n")
cat("  [plot]     institution : ", ifelse(is.na(col_inst),   "NOT FOUND", col_inst),   "\n")
cat("  [plot]     emission    : ", col_emis, "\n")
cat("  [plot]     dry matter  : ", ifelse(is.na(col_dm),     "NOT FOUND", col_dm),     "\n")
cat("  [plot]     pH          : ", ifelse(is.na(col_ph),     "NOT FOUND", col_ph),     "\n")
cat("  [plot]     acid flag   : ", ifelse(is.na(col_acid),   "NOT FOUND", col_acid),   "\n")
cat("  [plot]     meas.method : ", ifelse(is.na(col_meas),   "NOT FOUND (sensitivity analysis will be skipped)", col_meas), "\n")
cat("  [interval] pmid        : ", ifelse(is.na(col_pmid_i), "NOT FOUND", col_pmid_i), "\n")
cat("  [interval] cum.time    : ", ifelse(is.na(col_ct),     "NOT FOUND", col_ct),     "\n")
cat("  [interval] air.temp    : ", ifelse(is.na(col_air),    "NOT FOUND", col_air),    "\n")
cat("  [interval] wind        : ", ifelse(is.na(col_wind),   "NOT FOUND", col_wind),   "\n")

cat("\n--- Unique application method values (check against INJECTION_ABBREVIATIONS / TRAILING_SHOE_CODES) ---\n")
if (!is.na(col_app)) print(sort(unique(pdat[[col_app]])))
cat("\n--- Unique manure source values (check against STRICT_MAN_SOURCE) ---\n")
if (!is.na(col_manure)) print(sort(unique(pdat[[col_manure]])))
if (!is.na(col_meas)) {
  cat("\n--- Unique measurement method values (check against CHAMBER_METHOD_KEYWORDS) ---\n")
  print(sort(unique(pdat[[col_meas]])))
}

# Rename to canonical short names (data.table in place)
setnames(pdat, col_pmid_p, "pmid", skip_absent = TRUE)
setnames(pdat, col_emis,   "e_rel", skip_absent = TRUE)
if (!is.na(col_app))    setnames(pdat, col_app,    "app_method", skip_absent = TRUE)
if (!is.na(col_manure)) setnames(pdat, col_manure, "man_source", skip_absent = TRUE)
if (!is.na(col_inst))   setnames(pdat, col_inst,   "inst",       skip_absent = TRUE)
if (!is.na(col_dm))     setnames(pdat, col_dm,     "dm",         skip_absent = TRUE)
if (!is.na(col_ph))     setnames(pdat, col_ph,     "man_ph",     skip_absent = TRUE)
if (!is.na(col_acid))   setnames(pdat, col_acid,   "acid",       skip_absent = TRUE)
if (!is.na(col_meas))   setnames(pdat, col_meas,   "meas_method", skip_absent = TRUE)

setnames(idat, col_pmid_i, "pmid", skip_absent = TRUE)
setnames(idat, col_ct,     "ct",   skip_absent = TRUE)
setnames(idat, col_air,    "air_temp", skip_absent = TRUE)
if (!is.na(col_wind)) setnames(idat, col_wind, "wind", skip_absent = TRUE)

# =============================================================================
# SECTION 3: SHARED DERIVED VARIABLES AND BASE FILTERS  (-> pdat_clean)
# =============================================================================
# This is the single shared cleaning pipeline both analyses draw from.
# Filters applied here are the ones common to BOTH the time-of-day analysis
# and the early/late analysis (per the manuscript's stated exclusion
# criteria for each). Analysis-specific filtering happens later and is
# explicitly labelled as such.

msg("Deriving shared variables (hour of day, season, time-of-day category)...")

# --- Parsing t.start.p ---------------------------------------------------
# IMPORTANT: t.start.p is a hardcoded column name (unlike the other plot-level
# columns above, it does not go through the flexible find_col() resolver), and
# until this fix it was parsed with a bare as.POSIXct(t.start.p, tz = "UTC").
# That call assumes an ISO-style "%Y-%m-%d ..." string. ALFAM2-data exports
# (confirmed for the interval-level file's t.start/t.end columns, e.g.
# "27/02/2013 06:52") use DD/MM/YYYY HH:MM instead. Bare as.POSIXct() does NOT
# error on that format - it silently mis-parses it (e.g. "27/02/2013 06:52"
# becomes something like "27-02-20 UTC", losing the time-of-day entirely and
# scrambling the date), which is exactly the kind of bug that produces
# plausible-but-wrong output rather than a crash: totals stay correct (no rows
# are dropped) but hour_of_day - and therefore every Morning/Afternoon/Evening
# category count - comes out wrong. This is the leading candidate explanation
# for the Table 7 category-count shift reported (totals matched exactly;
# categories were redistributed).
#
# Fix: use lubridate::parse_date_time() with an explicit list of candidate
# formats (same defensive pattern already used for datetime parsing in
# 01_date_selector_with_smd.R), trying ISO forms first and DD/MM/YYYY forms
# next. This is safe regardless of which convention your particular database
# export uses - if t.start.p is already ISO-formatted, the ISO orders match
# first and nothing changes; if it's DD/MM/YYYY (as confirmed for the
# interval file), the earlier bare-POSIXct bug is fixed.
pdat[, t.start.p := parse_date_time(
  as.character(t.start.p),
  orders = c("Ymd HMS", "Ymd HM", "Y-m-d H:M:S", "Y-m-d H:M",
             "d/m/Y H:M:S", "d/m/Y H:M", "dmy HMS", "dmy HM"),
  tz = "UTC",
  quiet = TRUE
)]

# Diagnostic: print a handful of raw vs parsed values so a bad format
# assumption is visible immediately on next run, rather than silently
# producing plausible-but-wrong hour_of_day categories again. Also flags how
# many rows failed to parse under ANY of the orders above (these become NA
# and are excluded via the "valid hour-of-day" filter a few lines below,
# same as before - but a large NA count here would indicate the true format
# isn't covered by the orders list and needs to be added).
n_unparsed <- sum(is.na(pdat$t.start.p))
cat("\nt.start.p parsing check:\n")
cat("  Rows where parsing failed (all", length(c("Ymd HMS","Ymd HM","Y-m-d H:M:S","Y-m-d H:M",
    "d/m/Y H:M:S","d/m/Y H:M","dmy HMS","dmy HM")), "candidate formats failed):",
    n_unparsed, "of", nrow(pdat), "\n")
cat("  Sample of parsed t.start.p values (verify these look correct - i.e. plausible\n")
cat("  calendar dates with a non-zero, sensible time-of-day for most rows):\n")
print(head(pdat$t.start.p[!is.na(pdat$t.start.p)], 5))

pdat[, hour_of_day := {
  lt <- as.POSIXlt(t.start.p, tz = "UTC")
  as.numeric(lt$hour) + as.numeric(lt$min) / 60
}]
pdat[, `:=`(
  year_app  = as.integer(format(t.start.p, "%Y")),
  month_app = as.integer(format(t.start.p, "%m"))
)]

pdat[, time_cat := factor(
  fcase(
    hour_of_day >= MORNING_START   & hour_of_day < MORNING_END,   "Morning",
    hour_of_day >= AFTERNOON_START & hour_of_day < AFTERNOON_END, "Afternoon",
    hour_of_day >= EVENING_START   & hour_of_day < EVENING_END,   "Evening",
    !is.na(hour_of_day), "Other"
  ),
  levels = c("Morning", "Afternoon", "Evening", "Other")
)]

pdat[, season := factor(
  fcase(
    month_app %in% c(3, 4, 5),   "Spring",
    month_app %in% c(6, 7, 8),   "Summer",
    month_app %in% c(9, 10, 11), "Autumn",
    month_app %in% c(12, 1, 2),  "Winter"
  ),
  levels = c("Spring", "Summer", "Autumn", "Winter")
)]

if ("app_method" %in% names(pdat)) {
  pdat[, is_trailing_shoe := tolower(trimws(app_method)) %in% tolower(TRAILING_SHOE_CODES)]
} else {
  pdat[, is_trailing_shoe := FALSE]
}

pdat[, emis_pct := e_rel * 100]
# log(e_rel) on the full, still-unfiltered table will hit negative e_rel values
# (raw measurement noise not yet removed by the 0-105% TAN bound applied below),
# which produces an expected "NaNs produced" warning - harmless, since every row
# downstream is required to have is.finite(log_emis) before it reaches the
# early/late model (see the filter a few hundred lines below). Suppressed here
# so it doesn't read as a bug on every run; if you see it print anyway despite
# this suppressWarnings(), that's a real problem worth investigating.
pdat[, log_emis := suppressWarnings(log(e_rel))]

cat("\nt.start.p coverage (before any filtering):\n")
cat("  Total plots           : ", nrow(pdat), "\n")
cat("  Exactly midnight (0.0) : ", sum(pdat$hour_of_day == 0.0, na.rm = TRUE),
    " <- treated as date-only placeholder records (no time info) and excluded\n")

n_start <- nrow(pdat)

# ---- Shared filter 1: valid hour-of-day AND valid emission value ----
pdat_clean <- pdat[!is.na(hour_of_day) & !is.na(e_rel)]
msg("After requiring valid hour + emission: ", nrow(pdat_clean), " (removed ", n_start - nrow(pdat_clean), ")")

# ---- Shared filter 2: exclude midnight placeholder records (hour < 0.5) ----
# Rationale (from the original 04d investigation): a perfectly vertical
# cluster of points at x = 0.0 with no continuity into 1am/2am is the
# signature of date-only records where a missing time was defaulted to
# 00:00:00 by as.POSIXct(); genuine midnight starts would show
# minute-level jitter and continuity with neighbouring hours. These
# records carry no usable time-of-day information for EITHER analysis.
n_before <- nrow(pdat_clean)
n_midnight <- sum(pdat_clean$hour_of_day < 0.5, na.rm = TRUE)
pdat_clean <- pdat_clean[hour_of_day >= 0.5]
msg("After excluding midnight placeholders (hour < 0.5): ", nrow(pdat_clean),
    " (removed ", n_midnight, ")")

# ---- Shared filter 3: cumulative emission within 0-105% TAN ----
n_before <- nrow(pdat_clean)
pdat_clean <- pdat_clean[emis_pct >= MIN_EMISSION_FRAC * 100 & emis_pct <= MAX_EMISSION_FRAC * 100]
msg("After emission range filter [", MIN_EMISSION_FRAC * 100, "-", MAX_EMISSION_FRAC * 100, "% TAN]: ",
    nrow(pdat_clean), " (removed ", n_before - nrow(pdat_clean), ")")

# Snapshot BEFORE injection exclusion, for Part II (early/late analysis) to
# merge against. Manuscript Section 2.7.2 defines the early/late "full
# sample" base filter as only: valid hour + emission, midnight exclusion,
# and the 0-105% TAN emission bound - it does NOT mention excluding
# injection methods (unlike Section 2.7.1's Analysis A/B, which explicitly
# does: "excluding injection methods"). An earlier version of this script
# applied the injection exclusion to BOTH analyses via one shared pipeline
# stage, on the assumption that both source scripts used the same filter -
# that assumption doesn't hold here: it left the early/late "full sample"
# short by ~450 plots (1,715 computed vs 2,169 manuscript-reported) and
# distorted its wind/R2 model results (sample composition changed, since
# excluding injection also removes those plots' contribution to weather-
# period coverage). It's also inconsistent with the early/late model
# formula itself, which includes "application method" as a fixed-effect
# covariate to adjust for rather than a category to exclude - adjusting
# for a variable implies the excluded category should still be present in
# the data, otherwise there's nothing to adjust for.
pdat_clean_preinjection <- copy(pdat_clean)

# ---- Shared filter 4: exclude injection methods (Part I / Analysis A & B only) ----
if ("app_method" %in% names(pdat_clean)) {
  n_before <- nrow(pdat_clean)
  pdat_clean <- pdat_clean[!tolower(trimws(app_method)) %in% tolower(INJECTION_ABBREVIATIONS)]
  msg("After excluding injection methods (Part I / Analysis A & B only - NOT applied to Part II's early/late full sample, see comment above): ",
      nrow(pdat_clean), " (removed ", n_before - nrow(pdat_clean), ")")
  cat("\nApplication method distribution after cleaning (Part I basis):\n")
  print(table(pdat_clean$app_method))
} else {
  warning("Application method column not found - injection exclusion skipped")
}

msg("\nSHARED CLEANED DATASET (pdat_clean): ", nrow(pdat_clean), " plots from ",
    if ("inst" %in% names(pdat_clean)) length(unique(pdat_clean$inst)) else "unknown", " institutions.")
msg("This is the common starting point for both analyses below; further")
msg("filtering from this point is analysis-specific and documented at each step.\n")

# Chamber vs micrometeorological classification, computed once on the
# shared cleaned table so both Analysis A and Analysis B sensitivity
# analyses can reuse it directly.
if ("meas_method" %in% names(pdat_clean)) {
  chamber_regex <- paste(CHAMBER_METHOD_KEYWORDS, collapse = "|")
  pdat_clean[, is_chamber_method := grepl(chamber_regex, tolower(as.character(meas_method)), perl = TRUE)]
  pdat_clean[, is_micromet := !is.na(meas_method) & !is_chamber_method]
  msg("Measurement method classification: ", sum(pdat_clean$is_micromet, na.rm = TRUE),
      " micrometeorological, ", sum(pdat_clean$is_chamber_method, na.rm = TRUE), " chamber-based, ",
      sum(is.na(pdat_clean$meas_method)), " unclassified/missing.")
} else {
  pdat_clean[, is_micromet := NA]
  msg("No measurement-method column identified - micrometeorological sensitivity analysis will be skipped.")
}


# #############################################################################
# PART I: TIME-OF-DAY ANALYSIS  (Section 2.7.1 / 3.5.1)
# #############################################################################

msg("\n", strrep("=", 70))
msg("PART I: TIME-OF-DAY ANALYSIS")
msg(strrep("=", 70))

# ---- Analysis A: all surface application methods ----
dat_A <- pdat_clean[time_cat %in% c("Morning", "Afternoon", "Evening")]
dat_A[, time_cat := droplevels(time_cat)]

# ---- Analysis B: trailing shoe only ----
dat_B <- pdat_clean[is_trailing_shoe == TRUE & time_cat %in% c("Morning", "Afternoon", "Evening")]
dat_B[, time_cat := droplevels(time_cat)]

msg("Analysis A (all surface methods): n = ", nrow(dat_A), " plots from ",
    length(unique(dat_A$inst)), " institutions")
msg("Analysis B (trailing shoe only):  n = ", nrow(dat_B), " plots from ",
    length(unique(dat_B$inst)), " institutions")


if (nrow(dat_B) == 0) {
  stop("No trailing shoe plots found after filtering. Check TRAILING_SHOE_CODES ",
       "against the application method values printed in Section 2.")
}

# -----------------------------------------------------------------------------
# Section 3.5.1a: Spearman rank correlation (start hour vs cumulative emission)
# -----------------------------------------------------------------------------
# Spearman is used (rather than Pearson) because a linear/monotonic-but-not-
# necessarily-linear relationship between start hour and emission is more
# defensibly summarised by rank correlation; this also matches how the
# equivalent early/late-period correlations are reported.

cat("\n", strrep("=", 60), "\nCORRELATION: Start hour vs. cumulative emission (% TAN)\n", strrep("=", 60), "\n", sep = "")

cor_A <- cor.test(pdat_clean[time_cat %in% c("Morning", "Afternoon", "Evening"), hour_of_day],
                   pdat_clean[time_cat %in% c("Morning", "Afternoon", "Evening"), emis_pct],
                   method = "spearman", exact = FALSE)
cor_B <- cor.test(dat_B$hour_of_day, dat_B$emis_pct, method = "spearman", exact = FALSE)

cat(sprintf("Analysis A (all surface methods, n = %d): rho = %.3f, p = %s\n",
            nrow(dat_A), cor_A$estimate, fmt_p(cor_A$p.value)))
cat(sprintf("Analysis B (trailing shoe only,  n = %d): rho = %.3f, p = %s\n",
            nrow(dat_B), cor_B$estimate, fmt_p(cor_B$p.value)))


# -----------------------------------------------------------------------------
# Table 7: raw category means
# -----------------------------------------------------------------------------
# Output resolution: plot-level, cumulative emission at final measurement
# interval (% applied TAN). Not instantaneous, not spatially averaged.

summarise_by_tod <- function(dat, label) {
  dat[, .(
    Analysis     = label,
    n            = .N,
    mean_hour    = mean(hour_of_day),
    mean_emis    = mean(emis_pct, na.rm = TRUE),
    sd_emis      = sd(emis_pct, na.rm = TRUE),
    se_emis      = sd(emis_pct, na.rm = TRUE) / sqrt(.N),
    ci_lower     = mean(emis_pct, na.rm = TRUE) - qnorm(1 - (1 - CI_LEVEL) / 2) * sd(emis_pct, na.rm = TRUE) / sqrt(.N),
    ci_upper     = mean(emis_pct, na.rm = TRUE) + qnorm(1 - (1 - CI_LEVEL) / 2) * sd(emis_pct, na.rm = TRUE) / sqrt(.N)
  ), by = time_cat][order(time_cat)]
}

table7_A <- summarise_by_tod(dat_A, "All surface methods")
table7_B <- summarise_by_tod(dat_B, "Trailing shoe only")
table7   <- rbind(table7_A, table7_B)

# CSV: full-precision numeric columns, suitable for further statistics/plotting
table7_csv <- copy(table7)
setnames(table7_csv, "time_cat", "time_of_day")
table7_csv[, `:=`(mean_start_hour_decimal = round(mean_hour, 3),
                   mean_start_hour_hhmm   = format_hour_hm(mean_hour))]
table7_csv[, mean_hour := NULL]
table7_csv[, (c("mean_emis", "sd_emis", "se_emis", "ci_lower", "ci_upper")) :=
             lapply(.SD, round, 2), .SDcols = c("mean_emis", "sd_emis", "se_emis", "ci_lower", "ci_upper")]

# Word/display version: exact manuscript column set and formatting
table7_display <- data.table(
  Analysis                     = table7$Analysis,
  `Time of Day`                = as.character(table7$time_cat),
  n                            = table7$n,
  `Mean Start Hour`            = format_hour_hm(table7$mean_hour),
  `Mean Emission (% TAN)`      = sprintf("%.1f", table7$mean_emis),
  `95% CI (% TAN)`             = sprintf("%.1f to %.1f", table7$ci_lower, table7$ci_upper)
)

export_table(
  table7_csv, file.path(table_dir, "table07_tod_category_means"),
  caption_text = paste0(
    "Table 7. Observed cumulative NH3 emission fraction (% applied TAN at final measurement) ",
    "by time-of-day category from the ALFAM2 empirical database (", ALFAM2_VERSION_LABEL, "). ",
    "Plot-level, cumulative values (not model predictions, not spatially averaged). ",
    "Midnight-start records and injection application methods excluded; ",
    "emission restricted to 0-105% applied TAN."
  ),
  notes_text = "TAN = total ammoniacal nitrogen; CI = confidence interval.",
  # NB: table7_csv's time-of-day column is named "time_of_day" (set via setnames()
  # above), not "Time of Day" - that display-cased name only exists in
  # table7_display below. Passing "Time of Day" here made flextable::align()
  # look up a column that doesn't exist in this table, throwing
  # "`i` is using unknown variable(s): `Time of Day`" at export time.
  left_cols = c("Analysis", "time_of_day")
)
export_table(
  table7_display, file.path(table_dir, "table07_tod_category_means_display"),
  caption_text = paste0(
    "Table 7. Observed cumulative NH3 emission fraction (% applied TAN at final measurement) ",
    "by time-of-day category from the ALFAM2 empirical database (", ALFAM2_VERSION_LABEL, "). ",
    "Values are raw category means (unadjusted for covariates)."
  ),
  notes_text = "TAN = total ammoniacal nitrogen; CI = 95% confidence interval.",
  left_cols = c("Analysis", "Time of Day")
)

# -----------------------------------------------------------------------------
# Section 3.5.1b: Covariate-adjusted mixed-effects models
# -----------------------------------------------------------------------------
# Institution enters as a random intercept to account for clustering of
# experiments within research groups (shared equipment/protocols/climate).
#   Analysis A covariates: application method, manure source, season
#   Analysis B covariates: season only (method fixed - trailing shoe only;
#     manure source dropped to match the manuscript's Analysis B spec)
#
# Both the "vs Morning" and "vs Afternoon" contrasts for Evening are needed
# for the manuscript text. Rather than compute one and derive the other via
# a hand-built contrast matrix, the model is fit twice with a different
# reference level each time (`fit_time_cat_model` below) - this stays
# closest to the original scripts' approach (`relevel()` + refit) and is
# transparent to inspect.

build_fixed_rhs <- function(dat, extra_cols = character(0), include_season = TRUE) {
  parts <- character(0)
  for (col in extra_cols) {
    if (col %in% names(dat) && length(unique(na.omit(dat[[col]]))) > 1) parts <- c(parts, col)
  }
  if (include_season && length(unique(na.omit(dat$season))) > 1) parts <- c(parts, "season")
  paste(c("time_cat", parts), collapse = " + ")
}

fit_time_cat_model <- function(dat, fixed_rhs, ref_level, label) {
  d <- copy(dat)
  d[, time_cat := relevel(droplevels(time_cat), ref = ref_level)]
  rand_term <- if ("inst" %in% names(d) && length(unique(na.omit(d$inst))) > 2) "(1|inst)" else ""
  formula_str <- paste0("emis_pct ~ ", fixed_rhs, if (nchar(rand_term) > 0) paste0(" + ", rand_term) else "")
  mod <- tryCatch(
    lmer(as.formula(formula_str), data = d, REML = FALSE),
    error = function(e) {
      msg("  lmer failed for '", label, "' (ref = ", ref_level, "): ", conditionMessage(e), " - falling back to lm")
      # `fixed_rhs` already begins with "time_cat + ..." (built by
      # build_fixed_rhs()), so it can be used directly here without the
      # random-effects term.
      lm(as.formula(paste0("emis_pct ~ ", fixed_rhs)), data = d)
    }
  )
  mod
}

# Analysis A: method + manure + season, ref = Morning and ref = Afternoon
fixed_A <- build_fixed_rhs(dat_A, extra_cols = c("app_method", "man_source"))
cat("\nAnalysis A fixed effects:", fixed_A, "\n")
model_A_vsMorning   <- fit_time_cat_model(dat_A, fixed_A, "Morning",   "Analysis A")
model_A_vsAfternoon <- fit_time_cat_model(dat_A, fixed_A, "Afternoon", "Analysis A")

# Analysis B: season only, ref = Morning and ref = Afternoon
fixed_B <- build_fixed_rhs(dat_B, extra_cols = character(0))
cat("Analysis B fixed effects:", fixed_B, "\n")
model_B_vsMorning   <- fit_time_cat_model(dat_B, fixed_B, "Morning",   "Analysis B")
model_B_vsAfternoon <- fit_time_cat_model(dat_B, fixed_B, "Afternoon", "Analysis B")

saveRDS(model_A_vsMorning, file.path(output_dir, "lmm_tod_analysisA_vsMorning.rds"))
saveRDS(model_B_vsMorning, file.path(output_dir, "lmm_tod_analysisB_vsMorning.rds"))

A_eve_vs_morn <- get_term_stat(model_A_vsMorning,   "time_catEvening")
A_eve_vs_aft  <- get_term_stat(model_A_vsAfternoon, "time_catEvening")
B_eve_vs_morn <- get_term_stat(model_B_vsMorning,   "time_catEvening")
B_eve_vs_aft  <- get_term_stat(model_B_vsAfternoon, "time_catEvening")

cat("\nAnalysis A (all surface methods), covariate-adjusted:\n")
cat(sprintf("  Evening vs Morning:   %.2f%% TAN (SE = %.2f, p = %s)\n", A_eve_vs_morn$est, A_eve_vs_morn$se, fmt_p(A_eve_vs_morn$p)))
cat(sprintf("  Evening vs Afternoon: %.2f%% TAN (SE = %.2f, p = %s)\n", A_eve_vs_aft$est,  A_eve_vs_aft$se,  fmt_p(A_eve_vs_aft$p)))
cat("Analysis B (trailing shoe only), covariate-adjusted:\n")
cat(sprintf("  Evening vs Morning:   %.2f%% TAN (SE = %.2f, p = %s)\n", B_eve_vs_morn$est, B_eve_vs_morn$se, fmt_p(B_eve_vs_morn$p)))
cat(sprintf("  Evening vs Afternoon: %.2f%% TAN (SE = %.2f, p = %s)\n", B_eve_vs_aft$est,  B_eve_vs_aft$se,  fmt_p(B_eve_vs_aft$p)))


# -----------------------------------------------------------------------------
# Section 3.5.1c: Sensitivity analysis restricted to micrometeorological
# measurement methods (excludes chamber-based methods)
# -----------------------------------------------------------------------------
# See USER SETTINGS for the ambiguity around how "micrometeorological" is
# identified in this database release; classification was computed once
# above (`pdat_clean$is_micromet`) and is reused here for both A and B.

sensitivity_rows <- list()

if (all(is.na(pdat_clean$is_micromet))) {

  msg("\nSensitivity analysis SKIPPED: no measurement-method column identified in the database.")
  msg("Update MEAS_METHOD_COL_PATTERNS in USER SETTINGS if this column exists under a different name.")

} else {

  dat_A_micromet <- dat_A[is_micromet == TRUE]
  dat_B_micromet <- dat_B[is_micromet == TRUE]

  cat("\nMicrometeorological subset sizes:\n")
  cat("  Analysis A: n =", nrow(dat_A_micromet), " | category counts:\n"); print(table(dat_A_micromet$time_cat))
  cat("  Analysis B: n =", nrow(dat_B_micromet), " | category counts:\n"); print(table(dat_B_micromet$time_cat))

  # --- Analysis A sensitivity model ---
  if (nrow(dat_A_micromet) >= 10 && sum(dat_A_micromet$time_cat == "Evening") > 0) {
    fixed_A_mm <- build_fixed_rhs(dat_A_micromet, extra_cols = c("app_method", "man_source"))
    mod_A_mm_morn <- fit_time_cat_model(dat_A_micromet, fixed_A_mm, "Morning",   "Analysis A (micromet)")
    mod_A_mm_aft  <- fit_time_cat_model(dat_A_micromet, fixed_A_mm, "Afternoon", "Analysis A (micromet)")
    A_mm_eve_vs_morn <- get_term_stat(mod_A_mm_morn, "time_catEvening")
    A_mm_eve_vs_aft  <- get_term_stat(mod_A_mm_aft,  "time_catEvening")
    cat(sprintf("\nAnalysis A (micromet only, n = %d): Evening vs Morning = %.2f%% TAN (SE = %.2f, p = %s)\n",
                nrow(dat_A_micromet), A_mm_eve_vs_morn$est, A_mm_eve_vs_morn$se, fmt_p(A_mm_eve_vs_morn$p)))
    cat(sprintf("Analysis A (micromet only): Evening vs Afternoon = %.2f%% TAN (SE = %.2f, p = %s)\n",
                A_mm_eve_vs_aft$est, A_mm_eve_vs_aft$se, fmt_p(A_mm_eve_vs_aft$p)))
    sensitivity_rows[["A"]] <- data.table(
      Analysis = "All surface methods (micromet only)", n = nrow(dat_A_micromet),
      `Evening vs Morning (pp TAN)`   = sprintf("%.2f (SE %.2f, p %s)", A_mm_eve_vs_morn$est, A_mm_eve_vs_morn$se, fmt_p(A_mm_eve_vs_morn$p)),
      `Evening vs Afternoon (pp TAN)` = sprintf("%.2f (SE %.2f, p %s)", A_mm_eve_vs_aft$est,  A_mm_eve_vs_aft$se,  fmt_p(A_mm_eve_vs_aft$p))
    )
  } else {
    msg("Analysis A sensitivity model NOT ESTIMABLE (n = ", nrow(dat_A_micromet),
        "; Evening-category rows = ", sum(dat_A_micromet$time_cat == "Evening"), ")")
    sensitivity_rows[["A"]] <- data.table(
      Analysis = "All surface methods (micromet only)", n = nrow(dat_A_micromet),
      `Evening vs Morning (pp TAN)` = "not estimable", `Evening vs Afternoon (pp TAN)` = "not estimable"
    )
  }

  # --- Analysis B sensitivity model ---
  # Per the manuscript: the micrometeorological subset of the trailing shoe
  # data is expected to contain zero Evening-category records. We detect
  # this explicitly (rather than letting the model silently drop the level
  # or error) and report a clear, non-fatal "not estimable" result.
  n_B_mm_evening <- sum(dat_B_micromet$time_cat == "Evening")
  if (n_B_mm_evening == 0) {
    msg("Analysis B sensitivity model NOT ESTIMABLE: micrometeorological subset of trailing-shoe ",
        "data contains zero Evening-category records (n = ", nrow(dat_B_micromet),
        ", morning and afternoon only).")
    sensitivity_rows[["B"]] <- data.table(
      Analysis = "Trailing shoe only (micromet only)", n = nrow(dat_B_micromet),
      `Evening vs Morning (pp TAN)`   = "not estimable (no Evening-category records)",
      `Evening vs Afternoon (pp TAN)` = "not estimable (no Evening-category records)"
    )
  } else if (nrow(dat_B_micromet) >= 10) {
    # NOTE: this branch used to compute these coefficients silently (no
    # console output), only feeding the exported table - meaning the
    # numbers existed in table_tod_mixedmodel_coefficients.csv/.docx but
    # never appeared in the console log, easy to miss on a quick read. This
    # branch now fires for real (rather than the "not estimable, zero
    # Evening records" branch above) whenever the trailing-shoe
    # micrometeorological subset happens to include at least one Evening
    # record - which it does not always: it depends on exactly which plots
    # are in the database pull. Added an explicit cat() print here so the
    # numbers are visible immediately, and a warning about the small
    # Evening cell size specifically (distinct from the overall n, which
    # can look adequate while the Evening category alone is tiny).
    n_B_mm_evening_check <- sum(dat_B_micromet$time_cat == "Evening")
    cat(sprintf("\nAnalysis B (micromet only, n = %d, of which Evening = %d): computing Evening vs Morning/Afternoon.\n",
                nrow(dat_B_micromet), n_B_mm_evening_check))
    if (n_B_mm_evening_check < 10) {
      cat("  CAUTION: Evening cell n =", n_B_mm_evening_check,
          "- coefficient below is estimable but based on very few Evening records; treat as exploratory, not confirmatory.\n")
    }
    fixed_B_mm <- build_fixed_rhs(dat_B_micromet, extra_cols = character(0))
    mod_B_mm_morn <- fit_time_cat_model(dat_B_micromet, fixed_B_mm, "Morning",   "Analysis B (micromet)")
    mod_B_mm_aft  <- fit_time_cat_model(dat_B_micromet, fixed_B_mm, "Afternoon", "Analysis B (micromet)")
    B_mm_eve_vs_morn <- get_term_stat(mod_B_mm_morn, "time_catEvening")
    B_mm_eve_vs_aft  <- get_term_stat(mod_B_mm_aft,  "time_catEvening")
    cat(sprintf("Analysis B (micromet only): Evening vs Morning = %.2f%% TAN (SE = %.2f, p = %s)\n",
                B_mm_eve_vs_morn$est, B_mm_eve_vs_morn$se, fmt_p(B_mm_eve_vs_morn$p)))
    cat(sprintf("Analysis B (micromet only): Evening vs Afternoon = %.2f%% TAN (SE = %.2f, p = %s)\n",
                B_mm_eve_vs_aft$est, B_mm_eve_vs_aft$se, fmt_p(B_mm_eve_vs_aft$p)))
    sensitivity_rows[["B"]] <- data.table(
      Analysis = "Trailing shoe only (micromet only)", n = nrow(dat_B_micromet),
      `Evening vs Morning (pp TAN)`   = sprintf("%.2f (SE %.2f, p %s)", B_mm_eve_vs_morn$est, B_mm_eve_vs_morn$se, fmt_p(B_mm_eve_vs_morn$p)),
      `Evening vs Afternoon (pp TAN)` = sprintf("%.2f (SE %.2f, p %s)", B_mm_eve_vs_aft$est,  B_mm_eve_vs_aft$se,  fmt_p(B_mm_eve_vs_aft$p))
    )
  } else {
    sensitivity_rows[["B"]] <- data.table(
      Analysis = "Trailing shoe only (micromet only)", n = nrow(dat_B_micromet),
      `Evening vs Morning (pp TAN)` = "not estimable (insufficient n)",
      `Evening vs Afternoon (pp TAN)` = "not estimable (insufficient n)"
    )
  }
}

# -----------------------------------------------------------------------------
# Combined mixed-model coefficient table (main + sensitivity)
# -----------------------------------------------------------------------------

tod_model_table <- data.table(
  Analysis = c("All surface methods", "Trailing shoe only"),
  n = c(nrow(dat_A), nrow(dat_B)),
  `Evening vs Morning (pp TAN)`   = c(sprintf("%.2f (SE %.2f, p %s)", A_eve_vs_morn$est, A_eve_vs_morn$se, fmt_p(A_eve_vs_morn$p)),
                                       sprintf("%.2f (SE %.2f, p %s)", B_eve_vs_morn$est, B_eve_vs_morn$se, fmt_p(B_eve_vs_morn$p))),
  `Evening vs Afternoon (pp TAN)` = c(sprintf("%.2f (SE %.2f, p %s)", A_eve_vs_aft$est,  A_eve_vs_aft$se,  fmt_p(A_eve_vs_aft$p)),
                                       sprintf("%.2f (SE %.2f, p %s)", B_eve_vs_aft$est,  B_eve_vs_aft$se,  fmt_p(B_eve_vs_aft$p)))
)
if (length(sensitivity_rows) > 0) tod_model_table <- rbind(tod_model_table, rbindlist(sensitivity_rows, use.names = TRUE))

export_table(
  tod_model_table, file.path(table_dir, "table_tod_mixedmodel_coefficients"),
  caption_text = paste0(
    "Covariate-adjusted linear mixed-effects model coefficients for time-of-day effects on cumulative ",
    "NH3 emission (% applied TAN at final measurement), institution as random intercept. Analysis A ",
    "covariates: application method, manure source, season. Analysis B covariates: season. ",
    "Sensitivity rows restrict to micrometeorological measurement methods only (see script comments on ",
    "how this classification was made)."
  ),
  notes_text = paste0(
    "pp = percentage points; TAN = total ammoniacal nitrogen; SE = standard error. ",
    "\"not estimable\" indicates the model could not be fit for that contrast, most commonly because the ",
    "subset contained zero rows in the relevant time-of-day category."
  ),
  left_cols = "Analysis"
)

# -----------------------------------------------------------------------------
# Time-of-day figures (boxplot panel + scatter panel) - supporting figures,
# not individually numbered in the manuscript text supplied for this script.
# -----------------------------------------------------------------------------

dat_A_fig <- copy(dat_A); dat_A_fig[, analysis := "A: All surface methods"]
dat_B_fig <- copy(dat_B); dat_B_fig[, analysis := "B: Trailing shoe only"]
dat_tod_fig <- rbind(dat_A_fig[, .(time_cat, emis_pct, analysis)], dat_B_fig[, .(time_cat, emis_pct, analysis)])
panel_means <- dat_tod_fig[, .(mean_emis = mean(emis_pct, na.rm = TRUE), n = .N), by = .(analysis, time_cat)]

p_tod_box <- ggplot(dat_tod_fig, aes(x = time_cat, y = emis_pct, fill = time_cat)) +
  geom_boxplot(outlier.alpha = 0.2, width = 0.55) +
  geom_point(data = panel_means, aes(y = mean_emis), shape = 18, size = 3.2, colour = "black") +
  geom_text(data = panel_means, aes(y = mean_emis, label = sprintf("%.1f%%", mean_emis)),
            vjust = -0.7, size = 3.2, fontface = "bold", colour = "black") +
  scale_fill_manual(values = TOD_COLOURS, guide = "none") +
  scale_y_continuous(labels = function(x) paste0(x, "%"), expand = expansion(mult = c(0.02, 0.1))) +
  facet_wrap(~ analysis, scales = "free_y") +
  labs(title = "Observed NH3 emission by application time of day",
       subtitle = paste0("ALFAM2 database (", ALFAM2_VERSION_LABEL, ") | Diamonds = means"),
       x = "Application time category", y = "Cumulative emission (% applied TAN)",
       caption = "Plot-level cumulative emission at final measurement. Injection methods and midnight-start records excluded.") +
  theme_bw(base_size = 11) +
  theme(panel.grid.minor = element_blank(), panel.background = element_rect(fill = "white"),
        plot.title = element_text(face = "bold"), strip.text = element_text(face = "bold"),
        axis.title = element_text(face = "bold"), plot.caption = element_text(colour = "grey40", size = 7))
save_figure(p_tod_box, "fig_tod_boxplot_panel.png", FIG_WIDTH_DOUBLE, FIG_HEIGHT_DOUBLE)

make_scatter <- function(dat, cor_res, title_extra) {
  ggplot(dat, aes(x = hour_of_day, y = emis_pct, colour = time_cat)) +
    geom_point(alpha = 0.25, size = 1.2) +
    geom_smooth(method = "lm", colour = "grey20", se = TRUE, linewidth = 0.8) +
    annotate("text", x = max(dat$hour_of_day, na.rm = TRUE) * 0.75, y = max(dat$emis_pct, na.rm = TRUE) * 0.95,
             label = sprintf("rho = %.3f (n = %d)", cor_res$estimate, nrow(dat)), size = 3.6, fontface = "bold") +
    scale_colour_manual(values = TOD_COLOURS, name = "Time category") +
    scale_y_continuous(labels = function(x) paste0(x, "%")) +
    labs(title = paste0("NH3 emission vs. start hour - ", title_extra),
         x = "Application start hour (decimal, 24-h)", y = "Cumulative emission (% applied TAN)") +
    theme_bw(base_size = 11) +
    theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
          axis.title = element_text(face = "bold"))
}
p_scatter_A <- make_scatter(pdat_clean[time_cat %in% c("Morning", "Afternoon", "Evening")], cor_A, "Analysis A (all surface methods)")
p_scatter_B <- make_scatter(dat_B, cor_B, "Analysis B (trailing shoe only)")
save_figure(p_scatter_A, "fig_tod_scatter_analysisA.png", FIG_WIDTH_SINGLE * 1.6, FIG_HEIGHT_SINGLE * 1.4)
save_figure(p_scatter_B, "fig_tod_scatter_analysisB.png", FIG_WIDTH_SINGLE * 1.6, FIG_HEIGHT_SINGLE * 1.4)


# #############################################################################
# PART II: EARLY vs LATE PERIOD WEATHER ANALYSIS  (Section 2.7.2 / 3.5.2)
# #############################################################################

msg("\n", strrep("=", 70))
msg("PART II: EARLY (0-6h) vs LATE (6-24h) PERIOD WEATHER ANALYSIS")
msg(strrep("=", 70))

# -----------------------------------------------------------------------------
# Compute period-specific weather means from interval-level data
# -----------------------------------------------------------------------------
# This uses `idat` directly (not filtered by the plot-level exclusions in
# pdat_clean/pdat_clean_preinjection) because a plot's interval-level weather
# record can and should be summarised independently of whether that plot
# ultimately passes the plot-level QC filters; the merge below (Section
# "merge") then restricts to the intersection with `pdat_clean_preinjection`
# (not `pdat_clean` - see the injection-exclusion comment above for why).

idat_valid <- idat[!is.na(ct) & !is.na(air_temp) & !is.na(pmid)]
msg("Interval records with valid time + temperature: ", format(nrow(idat_valid), big.mark = ","))

has_wind <- "wind" %in% names(idat_valid) && sum(!is.na(idat_valid$wind)) > 1000
if (!has_wind) msg("WARNING: wind data limited or absent in interval file - wind models will be skipped")

idat_valid[, period := fcase(
  ct >= EARLY_PERIOD_START & ct <= EARLY_PERIOD_END, "early",
  ct > LATE_PERIOD_START & ct <= LATE_PERIOD_END, "late",
  default = "beyond"
)]

temp_means <- idat_valid[period %in% c("early", "late"),
                          .(mean_temp = mean(air_temp, na.rm = TRUE), n_obs = sum(!is.na(air_temp))),
                          by = .(pmid, period)]
temp_wide <- dcast(temp_means, pmid ~ period, value.var = c("mean_temp", "n_obs"))
setnames(temp_wide, c("mean_temp_early", "mean_temp_late", "n_obs_early", "n_obs_late"),
         c("temp_early", "temp_late", "n_temp_early", "n_temp_late"))

if (has_wind) {
  wind_means <- idat_valid[period %in% c("early", "late") & !is.na(wind),
                            .(mean_wind = mean(wind, na.rm = TRUE), n_obs = sum(!is.na(wind))),
                            by = .(pmid, period)]
  wind_wide <- dcast(wind_means, pmid ~ period, value.var = c("mean_wind", "n_obs"))
  setnames(wind_wide, c("mean_wind_early", "mean_wind_late", "n_obs_early", "n_obs_late"),
           c("wind_early", "wind_late", "n_wind_early", "n_wind_late"))
  period_means <- merge(temp_wide, wind_wide, by = "pmid", all = TRUE)
} else {
  period_means <- temp_wide
}
msg("Plots with period-level weather coverage: ", format(nrow(period_means), big.mark = ","))

# -----------------------------------------------------------------------------
# Merge with the shared cleaned plot-level data
# -----------------------------------------------------------------------------
# Uses `pdat_clean_preinjection` (valid hour + emission, midnight exclusion,
# 0-105% TAN emission range - deliberately WITHOUT the injection exclusion
# that Part I applies; see the comment at that filter step above for why).
# Left-joining period-level weather onto it and then requiring non-missing
# emission reproduces (in one step) what the source script did as separate
# post-merge filters, without repeating the filtering logic.

plot_cols <- intersect(c("pmid", "e_rel", "emis_pct", "log_emis", "app_method", "inst",
                          "dm", "man_source", "man_ph", "acid", "hour_of_day"),
                        names(pdat_clean_preinjection))
dat_el <- merge(period_means, pdat_clean_preinjection[, ..plot_cols], by = "pmid", all.x = FALSE)
msg("After merge with shared cleaned plot data: ", nrow(dat_el), " plots")

# Require minimum interval coverage in both periods, valid institution, and
# non-missing temperature in both periods (weather-specific completeness
# criteria that only apply to this analysis, hence not part of the shared
# base filters above).
n_before <- nrow(dat_el)
dat_el <- dat_el[n_temp_early >= MIN_OBS_PER_PERIOD & n_temp_late >= MIN_OBS_PER_PERIOD]
msg("After period coverage filter: ", nrow(dat_el), " (removed ", n_before - nrow(dat_el), ")")

n_before <- nrow(dat_el)
dat_el <- dat_el[!is.na(inst) & inst != ""]
msg("After valid-institution filter: ", nrow(dat_el), " (removed ", n_before - nrow(dat_el), ")")

n_before <- nrow(dat_el)
dat_el <- dat_el[!is.na(temp_early) & !is.na(temp_late) & is.finite(log_emis)]
msg("After temperature completeness / finite log(emission) filter: ", nrow(dat_el),
    " (removed ", n_before - nrow(dat_el), ")")

msg("\nFULL SAMPLE (early/late analysis): n = ", nrow(dat_el), " plots from ",
    length(unique(dat_el$inst)), " institutions")

# -----------------------------------------------------------------------------
# Strict subset: trailing shoe + unacidified cattle slurry, DM > 2%
# -----------------------------------------------------------------------------
# Manuscript Section 2.7.2 (Table S4) - see the USER SETTINGS comment above
# for the full reasoning: application method (trailing shoe) IS applied here
# as a real filter, in addition to the enumerated cattle/unacidified/DM > 2%
# criteria, based on matching the reported n = 188 (7 institutions) target.
# Applied first (before cattle/acid/pH/DM), matching the order used in the
# original component script this was harmonised from.

dat_el_strict <- copy(dat_el)

if ("app_method" %in% names(dat_el_strict)) {
  n_before <- nrow(dat_el_strict)
  dat_el_strict <- dat_el_strict[tolower(trimws(app_method)) %in% tolower(STRICT_APP_METHODS)]
  msg("Strict subset after trailing-shoe filter: ", nrow(dat_el_strict), " (removed ", n_before - nrow(dat_el_strict), ")")
} else {
  msg("  WARNING: app_method column not found in dat_el_strict; trailing-shoe filter NOT applied")
}

if ("man_source" %in% names(dat_el_strict)) {
  observed_man_source <- sort(unique(dat_el_strict$man_source))
  msg("  Observed man_source values in trailing-shoe subset: ", paste(observed_man_source, collapse = ", "))
  n_before <- nrow(dat_el_strict)
  matched <- tolower(dat_el_strict$man_source) %in% tolower(STRICT_MAN_SOURCE)
  if (sum(matched) == 0) {
    msg("  WARNING: no plots matched STRICT_MAN_SOURCE = ", paste(STRICT_MAN_SOURCE, collapse = ", "),
        ". Check observed values above and update STRICT_MAN_SOURCE. Cattle filter NOT applied this run.")
  } else {
    dat_el_strict <- dat_el_strict[matched]
    msg("Strict subset after cattle-slurry filter: ", nrow(dat_el_strict), " (removed ", n_before - nrow(dat_el_strict), ")")
  }
}

# Acidification exclusion: handle acid flag (logical/numeric/character) and
# pH threshold. Column type is branched on ONCE (outside any row-wise
# expression) because is.logical()/is.numeric()/is.character() describe the
# whole column, not a per-row condition.
if ("acid" %in% names(dat_el_strict)) {
  n_before <- nrow(dat_el_strict)
  acid_col <- dat_el_strict$acid
  if (is.logical(acid_col)) {
    acid_flag <- ifelse(is.na(acid_col), FALSE, acid_col)
  } else if (is.numeric(acid_col)) {
    acid_flag <- ifelse(is.na(acid_col), FALSE, acid_col == 1)
  } else {
    acid_flag <- tolower(trimws(as.character(acid_col))) %in% c("yes", "y", "true", "1", "acidified", "acid")
    acid_flag[is.na(acid_col)] <- FALSE
  }
  dat_el_strict <- dat_el_strict[!acid_flag]
  msg("Strict subset after acid-flag exclusion: ", nrow(dat_el_strict), " (removed ", n_before - nrow(dat_el_strict), ")")
}
if ("man_ph" %in% names(dat_el_strict)) {
  n_before <- nrow(dat_el_strict)
  dat_el_strict <- dat_el_strict[is.na(man_ph) | man_ph > STRICT_MIN_PH]
  msg("Strict subset after pH > ", STRICT_MIN_PH, " filter: ", nrow(dat_el_strict), " (removed ", n_before - nrow(dat_el_strict), ")")
}
if ("dm" %in% names(dat_el_strict)) {
  n_before <- nrow(dat_el_strict)
  dat_el_strict <- dat_el_strict[is.na(dm) | dm > STRICT_MIN_DM]
  msg("Strict subset after DM > ", STRICT_MIN_DM, "% filter: ", nrow(dat_el_strict), " (removed ", n_before - nrow(dat_el_strict), ")")
}

msg("\nSTRICT SUBSET (early/late analysis): n = ", nrow(dat_el_strict), " plots from ",
    length(unique(dat_el_strict$inst)), " institutions")

can_fit_strict <- nrow(dat_el_strict) >= 20 && length(unique(dat_el_strict$inst)) >= 2
if (!can_fit_strict) msg("WARNING: strict subset too small for reliable mixed-effects modelling")

# -----------------------------------------------------------------------------
# Model fitting function: log(cumulative emission) ~ early + late + DM
#   (+ application method) + (1|institution)
# -----------------------------------------------------------------------------
# MODEL SPEC NOTE: the manuscript text gives the exact formula
#   log(cumulative emission) ~ early_temp + late_temp + DM + application
#   method + (1|institution)
# which includes application method as a covariate. This differs from the
# internal draft script (04e), whose model omitted application method
# (only early/late weather + DM). This script follows the manuscript's
# stated formula, since that is the authoritative specification for this
# analysis; application method is included whenever it varies within the
# fitted subset (it will often collapse to a single level in the strict
# trailing-shoe-only subset, in which case it drops out automatically via
# `build_fixed_rhs`-style level-count checks below and the model reduces to
# the DM-only covariate spec).

run_early_late_model <- function(dat, weather_var_early, weather_var_late, label,
                                  include_app_method = TRUE) {

  use_dm <- "dm" %in% names(dat) && sum(!is.na(dat$dm)) > nrow(dat) * 0.5
  use_method <- include_app_method && "app_method" %in% names(dat) &&
    length(unique(na.omit(dat$app_method))) > 1

  covars <- c(if (use_dm) "dm", if (use_method) "app_method")
  fixed_rhs <- paste(c(weather_var_early, weather_var_late, covars), collapse = " + ")
  formula_str <- paste0("log_emis ~ ", fixed_rhs, " + (1|inst)")
  msg("  [", label, "] formula: ", formula_str)

  mod <- tryCatch(
    lmer(as.formula(formula_str), data = dat, REML = TRUE),
    error = function(e) {
      msg("  lmer failed for '", label, "' (", conditionMessage(e), ") - refitting without application method")
      lmer(as.formula(paste0("log_emis ~ ", weather_var_early, " + ", weather_var_late,
                              if (use_dm) " + dm" else "", " + (1|inst)")), data = dat, REML = TRUE)
    }
  )
  mod
}

get_early_late_stats <- function(mod, early_term, late_term) {
  cs <- coef(summary(mod))
  early <- get_term_stat(mod, early_term)
  late  <- get_term_stat(mod, late_term)
  diff <- early$est - late$est
  se_diff <- sqrt(early$se^2 + late$se^2)
  z <- diff / se_diff
  p_onesided <- pnorm(z, lower.tail = FALSE)   # H1: beta_early > beta_late
  list(early = early, late = late, diff = diff, se_diff = se_diff, p_onesided = p_onesided)
}

# -----------------------------------------------------------------------------
# Temperature models: full sample and strict subset
# -----------------------------------------------------------------------------

model_temp_full   <- run_early_late_model(dat_el,        "temp_early", "temp_late", "Full sample - temperature")
model_temp_strict <- if (can_fit_strict) run_early_late_model(dat_el_strict, "temp_early", "temp_late", "Strict subset - temperature") else NULL

stats_temp_full   <- get_early_late_stats(model_temp_full,   "temp_early", "temp_late")
stats_temp_strict <- if (!is.null(model_temp_strict)) get_early_late_stats(model_temp_strict, "temp_early", "temp_late") else NULL

cat(sprintf("\nFull sample temperature model: beta_early = %.4f (SE %.4f), beta_late = %.4f (SE %.4f)\n",
            stats_temp_full$early$est, stats_temp_full$early$se, stats_temp_full$late$est, stats_temp_full$late$se))
cat(sprintf("  Difference (early - late) = %.4f, one-sided p (early > late) = %s\n",
            stats_temp_full$diff, fmt_p(stats_temp_full$p_onesided)))


if (!is.null(stats_temp_strict)) {
  cat(sprintf("\nStrict subset temperature model: beta_early = %.4f (SE %.4f), beta_late = %.4f (SE %.4f)\n",
              stats_temp_strict$early$est, stats_temp_strict$early$se, stats_temp_strict$late$est, stats_temp_strict$late$se))
}

# -----------------------------------------------------------------------------
# Wind speed model - FULL SAMPLE ONLY
# -----------------------------------------------------------------------------
# The manuscript reports wind-speed coefficients for the full sample only;
# the strict-subset wind rows are reported as "-" in Table S4 due to
# limited sample size and collinearity between early/late wind speed in
# that smaller subset. Rather than fit an unstable strict-subset wind model
# and discard it, this script simply does not attempt it, and reports "-"
# directly, matching the manuscript's Table S4 exactly.

stats_wind_full <- NULL
if (has_wind && all(c("wind_early", "wind_late") %in% names(dat_el))) {
  dat_wind_full <- dat_el[!is.na(wind_early) & !is.na(wind_late)]
  if (nrow(dat_wind_full) > 50) {
    model_wind_full <- run_early_late_model(dat_wind_full, "wind_early", "wind_late", "Full sample - wind")
    stats_wind_full <- get_early_late_stats(model_wind_full, "wind_early", "wind_late")
    cat(sprintf("\nFull sample wind model: beta_early = %.4f (SE %.4f), beta_late = %.4f (SE %.4f), p (one-sided) = %s\n",
                stats_wind_full$early$est, stats_wind_full$early$se, stats_wind_full$late$est, stats_wind_full$late$se,
                fmt_p(stats_wind_full$p_onesided)))
  } else {
    msg("Insufficient wind coverage for full-sample wind model (n = ", nrow(dat_wind_full), ")")
  }
} else {
  msg("Wind data unavailable or insufficient - wind model skipped")
}

# -----------------------------------------------------------------------------
# Marginal R2: "Full model" (early+late temperature+DM+method, covariate-
# adjusted), and early-only / late-only UNIVARIATE weather models
# -----------------------------------------------------------------------------
# MODEL SPEC NOTE: the manuscript reports marginal R2 for a "full model"
# (both early- and late-period weather terms, covariate-adjusted) alongside
# early-only and late-only figures that are each markedly smaller and show a
# steep drop-off (full > early-only > late-only, roughly 4x and 7x smaller
# respectively). That pattern is only consistent with early-only/late-only
# being UNIVARIATE models - the single weather term alone, with no DM or
# application-method covariates - since most of the full model's explanatory
# power comes from the JOINT contribution of both weather terms together,
# not from the covariates. The full-model row below remains the
# covariate-adjusted specification whose coefficients are reported in-text;
# the early-only/late-only rows are fit as univariate models accordingly.
r2_full  <- r.squaredGLMM(model_temp_full)

# run_early_late_model() expects both an early and a late weather term, so
# the single-period models needed here are built with a small dedicated
# helper instead of contorting the shared helper to accept a NULL term.
build_single_period_model <- function(dat, weather_var, label) {
  formula_str <- paste0("log_emis ~ ", weather_var, " + (1|inst)")
  msg("  [", label, "] formula: ", formula_str)
  lmer(as.formula(formula_str), data = dat, REML = TRUE)
}
model_temp_early_only <- build_single_period_model(dat_el, "temp_early", "Full sample - early-only (univariate)")
model_temp_late_only  <- build_single_period_model(dat_el, "temp_late",  "Full sample - late-only (univariate)")

r2_early_only <- r.squaredGLMM(model_temp_early_only)
r2_late_only  <- r.squaredGLMM(model_temp_late_only)

r2m_full  <- unname(r2_full[1, "R2m"])
r2m_early <- unname(r2_early_only[1, "R2m"])
r2m_late  <- unname(r2_late_only[1, "R2m"])

cat(sprintf("\nMarginal R2 (full sample): full model = %.4f, early-only = %.4f, late-only = %.4f\n",
            r2m_full, r2m_early, r2m_late))

# Per the manuscript's Table S4, marginal R2 rows are not reported for the
# strict subset (shown as "-" for all "Model fit" rows), most plausibly
# because R2 estimates are unstable at n = 188 with 7 clusters. We compute
# it anyway for the console/QA record but display "-" in the exported
# table to match the manuscript exactly.
r2m_full_strict <- if (!is.null(model_temp_strict)) unname(r.squaredGLMM(model_temp_strict)[1, "R2m"]) else NA_real_
if (!is.na(r2m_full_strict)) {
  msg("(For reference only, not shown in Table S4 per the manuscript): strict-subset marginal R2 = ",
      round(r2m_full_strict, 4))
}

# -----------------------------------------------------------------------------
# Table S4
# -----------------------------------------------------------------------------

fmt_est_se <- function(est, se) if (is.na(est)) "—" else sprintf("%.4f (SE = %.4f)", est, se)
fmt_ratio  <- function(early, late) if (is.na(early) || is.na(late) || late == 0) "—" else sprintf("~%.1f×", abs(early / late))
fmt_num    <- function(x, digits = 4) if (is.na(x)) "—" else sprintf(paste0("%.", digits, "f"), x)

tableS4 <- data.table(
  Metric = c(
    "Temperature", "  Early-period (0-6h) coefficient, β", "  Late-period (6-24h) coefficient, β",
    "  Early:late ratio", "  Difference (early - late)", "  p-value (one-sided: βearly > βlate)",
    "Wind speed", "  Early-period (0-6h) coefficient, β", "  Late-period (6-24h) coefficient, β",
    "  p-value (one-sided: βearly > βlate)",
    "Model fit (marginal R2)", "  Full model", "  Early-period-only model", "  Late-period-only model"
  ),
  `Full sample` = c(
    "", fmt_est_se(stats_temp_full$early$est, stats_temp_full$early$se), fmt_est_se(stats_temp_full$late$est, stats_temp_full$late$se),
    fmt_ratio(stats_temp_full$early$est, stats_temp_full$late$est), fmt_num(stats_temp_full$diff), fmt_num(stats_temp_full$p_onesided, 3),
    "",
    if (!is.null(stats_wind_full)) fmt_est_se(stats_wind_full$early$est, stats_wind_full$early$se) else "—",
    if (!is.null(stats_wind_full)) fmt_est_se(stats_wind_full$late$est,  stats_wind_full$late$se)  else "—",
    if (!is.null(stats_wind_full)) fmt_num(stats_wind_full$p_onesided, 3) else "—",
    "", fmt_num(r2m_full, 3), fmt_num(r2m_early, 3), fmt_num(r2m_late, 3)
  ),
  `Strict subset` = c(
    "",
    if (!is.null(stats_temp_strict)) fmt_est_se(stats_temp_strict$early$est, stats_temp_strict$early$se) else "—",
    if (!is.null(stats_temp_strict)) fmt_est_se(stats_temp_strict$late$est,  stats_temp_strict$late$se)  else "—",
    if (!is.null(stats_temp_strict)) fmt_ratio(stats_temp_strict$early$est, stats_temp_strict$late$est) else "—",
    if (!is.null(stats_temp_strict)) fmt_num(stats_temp_strict$diff) else "—",
    if (!is.null(stats_temp_strict)) fmt_num(stats_temp_strict$p_onesided, 3) else "—",
    "", "—", "—", "—",   # wind not fitted for strict subset - see comment above
    "", "—", "—", "—"    # R2 not reported for strict subset, per manuscript Table S4
  )
)
setnames(tableS4, c("Full sample", "Strict subset"),
         c(sprintf("Full sample (n = %s; %d institutions)", format(nrow(dat_el), big.mark = ","), length(unique(dat_el$inst))),
           sprintf("Strict subset (n = %d; %d institutions)", nrow(dat_el_strict), length(unique(dat_el_strict$inst)))))

export_table(
  tableS4, file.path(table_dir, "tableS4_early_late_coefficients"),
  caption_text = paste0(
    "Table S4. Mixed-effects model coefficients for the effect of early-period (0-6h) versus late-period ",
    "(6-24h) weather conditions on cumulative NH3 emission. Model: log(cumulative emission) ~ early + late ",
    "+ dry matter + application method + (1|institution). Full sample: all plots with interval-level weather ",
    "data, midnight-start records and emission outside 0-105% TAN excluded. Strict subset: unacidified cattle ",
    "slurry, DM > ", STRICT_MIN_DM, "%, applied by trailing shoe, representing conditions approximating Irish ",
    "trailing-shoe practice. Wind-speed coefficients and marginal R2 are not reported for the strict subset ",
    "(—) owing to limited sample size and collinearity."
  ),
  notes_text = "SE = standard error; R2 = marginal R2 (fixed effects only, via MuMIn::r.squaredGLMM). — = not estimated/reported.",
  left_cols = "Metric"
)

# -----------------------------------------------------------------------------
# Figure 4: mixed-effects model coefficients (early vs late, temperature vs
# wind, 95% CI error bars), full sample only
# -----------------------------------------------------------------------------

z_crit <- qnorm(1 - (1 - CI_LEVEL) / 2)
period_levels <- c("Early\n(0-6h)", "Late\n(6-24h)")
period_colours <- c("Early\n(0-6h)" = "#D55E00", "Late\n(6-24h)" = "#0072B2")

coef_rows <- data.table(
  variable = c("Temperature", "Temperature"),
  period   = factor(period_levels, levels = period_levels),
  estimate = c(stats_temp_full$early$est, stats_temp_full$late$est),
  se       = c(stats_temp_full$early$se,  stats_temp_full$late$se)
)
if (!is.null(stats_wind_full)) {
  coef_rows <- rbind(coef_rows, data.table(
    variable = c("Wind Speed", "Wind Speed"),
    period   = factor(period_levels, levels = period_levels),
    estimate = c(stats_wind_full$early$est, stats_wind_full$late$est),
    se       = c(stats_wind_full$early$se,  stats_wind_full$late$se)
  ))
}
coef_rows[, `:=`(ci_lower = estimate - z_crit * se, ci_upper = estimate + z_crit * se)]

fig4 <- ggplot(coef_rows, aes(x = period, y = estimate, colour = period)) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50", linewidth = 0.4) +
  geom_errorbar(aes(ymin = ci_lower, ymax = ci_upper), width = 0.15, linewidth = 0.7) +
  geom_point(size = 3) +
  scale_colour_manual(values = period_colours, guide = "none") +
  facet_wrap(~ variable, scales = "free_y") +
  labs(
    title = "Early vs late period weather effects on ammonia emission",
    subtitle = paste0("ALFAM2 database (", ALFAM2_VERSION_LABEL, "), full sample: n = ",
                       format(nrow(dat_el), big.mark = ","), " plots from ", length(unique(dat_el$inst)), " institutions"),
    x = "Time Period After Application",
    y = "Coefficient\n(effect on log emission per unit increase)",
    caption = "Error bars: 95% CI. Mixed-effects model with institution as random intercept."
  ) +
  theme_bw(base_size = 11) +
  theme(
    panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
    panel.background = element_rect(fill = "white"),
    plot.title = element_text(face = "bold", size = 12),
    plot.subtitle = element_text(colour = "grey30", size = 9),
    strip.text = element_text(face = "bold"), strip.background = element_rect(fill = "grey95"),
    axis.title = element_text(face = "bold", size = 10),
    plot.caption = element_text(colour = "grey40", size = 7, hjust = 0)
  )

save_figure(fig4, "fig4_early_vs_late_coefficients.png", FIG_WIDTH_DOUBLE, FIG_HEIGHT_DOUBLE)

# Save model objects for downstream re-use / audit
saveRDS(model_temp_full, file.path(output_dir, "lmm_earlylate_temp_full.rds"))
if (!is.null(model_temp_strict)) saveRDS(model_temp_strict, file.path(output_dir, "lmm_earlylate_temp_strict.rds"))

# =============================================================================
# FINAL SUMMARY
# =============================================================================

cat("\n", strrep("=", 78), "\n", sep = "")
cat("RUN SUMMARY: 05_empirical_database_analysis.R\n")
cat(strrep("=", 78), "\n\n")

cat("OUTPUTS WRITTEN TO:", output_dir, "\n\n")

cat("Tables (", table_dir, "):\n", sep = "")
cat("  - table07_tod_category_means(.csv / _display.csv / .docx)   [Table 7]\n")
cat("  - table_tod_mixedmodel_coefficients.csv / .docx              [ToD models + sensitivity]\n")
cat("  - tableS4_early_late_coefficients.csv / .docx                [Table S4]\n\n")

cat("Figures (", figure_dir, "):\n", sep = "")
cat("  - fig_tod_boxplot_panel.png\n")
cat("  - fig_tod_scatter_analysisA.png / fig_tod_scatter_analysisB.png\n")
cat("  - fig4_early_vs_late_coefficients.png                        [Figure 4]\n\n")

cat("Sample sizes:\n")
cat(sprintf("  ToD Analysis A (all surface methods): n = %d plots, %d institutions\n",
            nrow(dat_A), length(unique(dat_A$inst))))
cat(sprintf("  ToD Analysis B (trailing shoe only):   n = %d plots, %d institutions\n",
            nrow(dat_B), length(unique(dat_B$inst))))
cat(sprintf("  Early/late full sample:                n = %d plots, %d institutions\n",
            nrow(dat_el), length(unique(dat_el$inst))))
cat(sprintf("  Early/late strict subset:              n = %d plots, %d institutions\n",
            nrow(dat_el_strict), length(unique(dat_el_strict$inst))))

msg("\nDone.")
