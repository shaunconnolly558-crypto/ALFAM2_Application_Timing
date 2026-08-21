Why Timing Matters: Evening Slurry Spreading for Ammonia Emission Reduction
A modelling and database analysis of evening slurry spreading for ammonia emission reduction, using Ireland as a case study. Combines an ALFAM2 Monte Carlo simulation framework with empirical analysis of the ALFAM2 measurement database to evaluate the effect of time-of-day on NH₃ emissions from cattle slurry applied by trailing shoe.
Citation
If you use this code, please cite the accompanying paper:
Connolly, S., Pedersen, J. Why timing matters: A modelling and database analysis of evening slurry spreading for ammonia emission reduction, using Ireland as a case study. [Journal] [submitted].
DOI
The Monte Carlo simulation dataset underlying this study is archived separately on Zenodo: https://doi.org/10.5281/zenodo.21511498
Overview
This repository contains the complete analysis pipeline behind the study, comprising two complementary lines of evidence:
1.	A simulation framework combining the ALFAM2 model with Monte Carlo uncertainty propagation. Hourly meteorological data from 22 stations across 14 counties over 13 years (2013–2025) were used to construct 1,358 realistic spreading scenarios (4,074 station×date×time-of-day combinations), each run with 101 ALFAM2 parameter sets and 50 stochastic slurry property draws (~20.6 million individual predictions).
2.	Empirical verification using three nested analyses of the ALFAM2 measurement database, covering up to 2,169 field plots from 25 research institutions.
Evening application (19:00) consistently produced the lowest predicted cumulative 168-hour emissions — a mean reduction of 0.64% TAN relative to morning across the 101 parameter sets, with evening optimal in ~88% of scenarios tested. The empirical database analysis independently confirmed both the direction and mechanistic basis of this effect.
Pipeline
The scripts are numbered to run sequentially. Steps 1–3 generate the simulation dataset; steps 4–5 are the harmonised analysis framework that reproduces every table and figure in the manuscript.
Step	Script	Description
1	01_date_selector_with_smd.R	Select spreading dates using weather criteria and Soil Moisture Deficit filtering (Schulte et al. 2005 Hybrid SMD Model)
1b	01b_date_gap_analysis_and_recovery.R	Analyse gaps from Step 1 and recover dates using progressively relaxed criteria
2	02_scenario_generator.R	Generate ALFAM2 scenarios with three daily time blocks (07:00 / 13:00 / 19:00) and 168-hour weather slices
3	03_monte_carlo.R	Run Monte Carlo simulation with ALFAM2 parameter uncertainty and slurry property distributions
4	04_simulation_analysis.R	Harmonised simulation analysis. Reproduces manuscript Tables 1–6, S1–S3, Figures 2–3, and the variance decomposition (§3.1–3.4, 3.6)
5	05_empirical_database_analysis.R	Harmonised empirical database analysis. Reproduces manuscript Table 7, Table S4, Figure 4, and the time-of-day / early-late period analyses (§3.5.1–3.5.2)
System Requirements
Steps 1, 1b, and 2 (date selection, gap recovery, scenario generation) are lightweight and run in under a minute on any modern laptop. Step 3 (the COMPREHENSIVE Monte Carlo run) is the bottleneck, it evaluates ALFAM2 roughly 20.6 million times (101 parameter sets x 50 slurry draws x ~4,074 scenarios) and needs a machine with enough cores and RAM to parallelise that workload. Steps 4 and 5 (the harmonised analysis scripts) are comparatively fast once mc_results_master.csv exists (a couple of minutes), since they operate on the pre-computed summary output rather than re-running ALFAM2.
Component	Minimum	Recommended (used for this study)
CPU cores	8	16
RAM	32 GB	64 GB
Step 3 runtime (COMPREHENSIVE mode)	Several hours to overnight, depending on cores	~10 hours on 16 cores / 64 GB
Steps 1–2 runtime	<1 minute each	<1 minute each
Steps 4–5 runtime	A few minutes	~2 minutes
Notes:
•	A 4-core laptop is not sufficient for the COMPREHENSIVE Monte Carlo run, it was tested and could not complete it in a reasonable time. 8 cores is a workable floor; more cores shorten the walltime roughly proportionally via the future.apply parallelisation in 03_monte_carlo.R.
•	16 GB RAM is likely too little. 32 GB is reasonable; 64 GB gives headroom, particularly if you keep other applications open or increase n_param_sets/n_mc_draws beyond the COMPREHENSIVE preset.
•	If you don’t have access to a suitable machine, reduce the workload first: set RUN_MODE in 03_monte_carlo.R’s USER SETTINGS to "TEST" or "QUICK" (see the run-mode table in that script) to verify the pipeline works before committing to a COMPREHENSIVE run, or reduce n_cores if running alongside other work.
•	No GPU is required — ALFAM2 and the Monte Carlo loop are CPU-bound.
•	Simultaneous multithreading (SMT / Hyper-Threading) made no meaningful difference to runtime when tested on the 16-core reference workstation (16 physical cores, 32 logical with SMT enabled) — Step 3’s walltime was essentially the same with SMT on or off. This workload is more constrained by memory bandwidth and per-core ALFAM2 evaluation cost than by having extra logical threads to schedule onto, so there’s no reason to chase logical-core count. Enable or disable SMT per your own preference (power draw, thermals, other workloads on the machine), it won’t cost or gain you meaningful time here either way.
•	These figures reflect one successful run on a 16-core / 64 GB workstation; treat them as a working reference point rather than a hard specification, since actual requirements scale with n_param_sets x n_mc_draws x scenario count, which you may adjust.
Getting Started
Prerequisites
R (≥ 4.1.0) with the following packages:
install.packages(c(
  "data.table", "ALFAM2", "ggplot2", "readxl", "lubridate",
  "truncnorm", "future", "future.apply", "zoo", "tools",
  "lme4", "lmerTest", "emmeans", "broom.mixed",
  "flextable", "officer", "patchwork", "mgcv",
  "viridis", "RColorBrewer", "scales", "ggpubr",
  "boot", "parallel", "quantreg"
))
Data Setup
Place your input data in the data/ directory (see data/README.md for full details on required file formats):
data/
├── weather/              # Hourly weather files (.xlsx) per station
├── Station_metadata.xlsx # Station coordinates, nitrate zones
├── Slurry_Baseline.xlsx  # Baseline slurry properties for ALFAM2
└── ALFAM2/                # ALFAM2 measurement database (for step 5) - downloaded
    ├── ALFAM2_plot.csv.gz  #   and cached here automatically; see data/README.md
    └── ALFAM2_interval.csv.gz
Running the Pipeline
1.	Set your working directory to the project root
2.	Run scripts in numerical order (each script reads from the previous step’s output)
3.	All scripts have a USER SETTINGS section at the top with configurable paths and parameters
setwd("/path/to/alfam2-ireland-timing")
source("R/01_date_selector_with_smd.R")
source("R/01b_date_gap_analysis_and_recovery.R")
source("R/02_scenario_generator.R")
source("R/03_monte_carlo.R")
source("R/04_simulation_analysis.R")
source("R/05_empirical_database_analysis.R")
Output is written to output/ with subdirectories per step. Steps 4 and 5 each print a run summary at completion, listing the tables and figures written and the sample sizes used.
Key Findings
•	Evening application (19:00) consistently produced the lowest predicted cumulative 168-hour NH₃ emissions across all 22 stations, all seasons, and all 101 ALFAM2 parameter sets
•	Mean evening advantage: 0.64% TAN vs morning (6.1% relative reduction) and 0.59% TAN vs afternoon, averaged across all 101 parameter sets; 0.71% TAN and 0.69% TAN respectively using the central parameter set alone
•	Evening produced the lowest mean emission in ~88% of the 1,358 scenarios tested
•	Empirical analysis of the independent ALFAM2 measurement database confirmed the effect: covariate-adjusted mixed-effects models showed reductions of 6.85% TAN (all surface methods, n=2,001) and 12.80% TAN (trailing shoe only, n=302) for evening vs morning application
•	Early-period (0–6h post-application) temperature has approximately ten times the influence of late-period (6–24h) temperature on cumulative emission, consistent with the kinetic mechanism of the evening advantage
•	The evening advantage is projected to grow under climate warming, from 0.64 to 0.70% TAN by 2050
Data Availability
•	Simulation output dataset: Zenodo
•	Weather data: Met Éireann hourly observations (available from Met Éireann) — not redistributable, so not included in this repository
•	ALFAM2 model and parameter sets: ALFAM2 R package
•	ALFAM2 empirical database: ALFAM2-data
•	Slurry property distributions: derived from Irish literature values (see manuscript Table 1 and its sources)
Licence
This project is licensed under the GPL-3.0 Licence — see the LICENCE file for details.
Contact
Shaun Connolly, Teagasc, Environment, Soils and Land Use Department, Johnstown Castle, Co. Wexford, Ireland. Shaun.connolly@teagasc.ie
