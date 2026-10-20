# Standalone Parquet x Sluice experiment (R1).
#
# Whole directory is behind DUDUDU_ENABLE_PARQUET, so the default and
# sluice-only configurations never see Arrow. Enabling it without the Arrow,
# Parquet and Google Benchmark packages present is a hard configure error,
# never a silent skip.
#
# This file grows with the experiment: targets appear together with the
# sources that back them.

find_package(Arrow REQUIRED)
find_package(Parquet REQUIRED)
find_package(benchmark CONFIG REQUIRED)

message(STATUS "Parquet experiment: Arrow ${Arrow_VERSION}, Parquet ${Parquet_VERSION}")
