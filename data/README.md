Data Directory
Place your input data files here before running the pipeline.
Required Structure
data/
├── weather/                  # Hourly weather station files
│   ├── Ballyhaise.xlsx
│   ├── Cork Airport.xlsx
│   ├── Johnstown Castle.xlsx
│   └── ... (one file per station)
├── Station_metadata.xlsx     # Station metadata
├── Slurry_Baseline.xlsx      # Baseline slurry properties
└── ALFAM2/                   # Used by R/05_empirical_database_analysis.R
    ├── ALFAM2_plot.csv.gz
    └── ALFAM2_interval.csv.gz
Weather Files
Each station file should contain hourly observations with at minimum four columns:
Column	Description	Units
datetime	Date and time	Various formats accepted
rain	Rainfall	mm/hr
temp	Air temperature	°C
wind	Wind speed (2m)	m/s
Column names are normalised automatically — common variants (e.g., air_temp, rain_rate, wind.2m) are recognised.
Source: Met Éireann hourly observations, available from https://www.met.ie/climate/available-data/historical-data
Station Metadata
Station_metadata.xlsx should contain one row per station with columns:
Column	Description
station_name	Name matching the weather file
latitude	Decimal degrees
longitude	Decimal degrees
nitrate_zone	A, B, or C
Slurry Baseline
Slurry_Baseline.xlsx should contain baseline slurry properties for ALFAM2:
Column	Description	Units
man.dm	Dry matter content	%
man.ph	Slurry pH	-
app.rate	Application rate	t/ha
tan.app	TAN applied	kg N/ha
app.mthd	Application method	e.g., “ts” for trailing shoe
ALFAM2 Database Files
You do not need to download these manually. R/05_empirical_database_analysis.R downloads ALFAM2_plot.csv.gz and ALFAM2_interval.csv.gz automatically on first run and caches them at data/ALFAM2/<tag>_<period>/, so subsequent runs reuse the cached copy without re-downloading. This is controlled by the ALFAM2_VERSION_TAG and ALFAM2_SUBMISSION_PERIOD settings near the top of that script (USER SETTINGS), which default to the current ALFAM2-data release (v3.0) and its current submission period (04), the dataset the ALFAM2-data maintainers themselves point users to as authoritative.
ALFAM2-data (https://github.com/AU-BCE-EE/ALFAM2-data) is actively updated: institutions add and revise plot submissions over time, so a download today will not exactly match a download taken months apart. The repository organises its data into a release tag (e.g. v3.0) and a “submission period” subfolder (currently 01–04); period 04 is the actively maintained current build, with earlier periods retained as frozen historical snapshots. Pinning both the tag and the submission period, as this script does, ensures a given run is reproducible.
To use a different version or period, change ALFAM2_VERSION_TAG and/or ALFAM2_SUBMISSION_PERIOD in the script; the local cache path is tagged by both settings, so a different combination downloads fresh without touching any existing cache. ALFAM2_VERSION_LABEL in the script’s output (table captions, notes) always states both the tag and the submission period used for that run.
If you need to work offline, set ALFAM2_ALLOW_DOWNLOAD <- FALSE in the script and place the two files manually at data/ALFAM2/<tag>_<period>/ALFAM2_plot.csv.gz and data/ALFAM2/<tag>_<period>/ALFAM2_interval.csv.gz yourself (download links follow the pattern https://raw.githubusercontent.com/AU-BCE-EE/ALFAM2-data/<tag>/data-output/<period>/<filename>).
Note
Data files are excluded from version control via .gitignore because they are either too large for GitHub or not freely redistributable. See the README in the project root for data availability information.
