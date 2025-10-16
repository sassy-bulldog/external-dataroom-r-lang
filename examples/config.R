# Example Usage of Parameterized Underwriting Archive
# This script demonstrates how to use the new parameterized approach

# Method 1: Render RMarkdown with default parameters
# rmarkdown::render("underwriting_archive.Rmd")

# Method 2: Render RMarkdown with custom parameters
library(rmarkdown)

# Define your custom parameters
custom_params <- list(
  current_period = "2025Q3",
  run_staging_directory = "C:/temp/staging/2025Q3/",
  output_staging_directory = "C:/temp/output/2025Q3/",
  source_directory = "C:/source_files/2025Q3/",
  archive_directory = "C:/archive/content/",
  archive_staging_directory = "C:/archive/content/",
  remove_working_files = TRUE
)

# Render with custom parameters
# rmarkdown::render(
#   "underwriting_archive.Rmd",
#   params = custom_params,
#   output_file = paste0("underwriting_archive_", custom_params$current_period, ".html")
# )

# Method 3: Call the function directly
source("../underwriting_functions.R")

# result <- archive_underwriting_files(
#   current_period = custom_params$current_period,
#   run_staging_directory = custom_params$run_staging_directory,
#   output_staging_directory = custom_params$output_staging_directory,
#   source_directory = custom_params$source_directory,
#   archive_directory = custom_params$archive_directory,
#   archive_staging_directory = custom_params$archive_staging_directory,
#   remove_working_files = custom_params$remove_working_files
# )

# Print results summary
# cat("Process completed. Files copied:", result$files_copied, "\n")