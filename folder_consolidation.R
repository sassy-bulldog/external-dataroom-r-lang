# Folder-Level Archive Consolidation
# 
# This script provides functions to consolidate file-level archives into
# folder-level archives for final deployment. It reads the metadata/JSON
# from the staging area and reorganizes files at the segment/deal folder level.

library(tidyverse)
library(fs)
library(jsonlite)

#' Consolidate Files to Folder-Level Archive
#'
#' Reads the staging metadata and creates a folder-level archive where:
#' - If ANY file in a segment/deal folder changed, ALL files are copied
#' - Priority: MODIFIED > NEW > UNCHANGED
#' - RENAMED is treated as MODIFIED for archiving
#' - Allows remapping NEW files to MODIFIED if folder has modifications
#'
#' @param staging_path Path to the staging directory (e.g., "./temp_staging/2025Q3")
#' @param final_archive_path Path to create the final consolidated archive
#' @param source_path Path to the original source files
#' @return List with consolidation results and statistics
#' @export
consolidate_to_folder_archive <- function(staging_path, final_archive_path, source_path) {
  
  message("=== Folder-Level Archive Consolidation ===")
  message("Staging Path: ", staging_path)
  message("Final Archive: ", final_archive_path)
  
  # Load metadata and file summary
  quarter_id <- path_file(staging_path)
  metadata_file <- path(staging_path, paste0(quarter_id, "_metadata.json"))
  summary_file <- path(staging_path, paste0(quarter_id, "_file_summary.csv"))
  
  if(!file_exists(metadata_file) || !file_exists(summary_file)) {
    stop("Missing required files in staging path")
  }
  
  metadata <- read_json(metadata_file, simplifyVector = TRUE)
  file_summary <- read_csv(summary_file, show_col_types = FALSE)
  
  # Analyze folder-level changes
  folder_analysis <- file_summary %>%
    group_by(segment, deal) %>%
    summarise(
      total_files = n(),
      new_count = sum(status == "NEW", na.rm = TRUE),
      modified_count = sum(status == "MODIFIED", na.rm = TRUE),
      renamed_count = sum(status == "RENAMED", na.rm = TRUE),
      reintroduced_count = sum(status == "REINTRODUCED", na.rm = TRUE),
      unchanged_count = sum(status == "UNCHANGED", na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      # Determine folder action based on priority:
      # MODIFIED/RENAMED > NEW/REINTRODUCED > UNCHANGED
      folder_action = case_when(
        modified_count > 0 | renamed_count > 0 ~ "MODIFIED",
        new_count > 0 | reintroduced_count > 0 ~ "NEW",
        TRUE ~ "UNCHANGED"
      )
    )
  
  # Print folder analysis
  message("\n=== Folder Analysis ===")
  message("Total folders: ", nrow(folder_analysis))
  message("NEW folders: ", sum(folder_analysis$folder_action == "NEW"))
  message("MODIFIED folders: ", sum(folder_analysis$folder_action == "MODIFIED"))
  message("UNCHANGED folders: ", sum(folder_analysis$folder_action == "UNCHANGED"))
  
  # Create final archive structure
  new_dir <- path(final_archive_path, "NEW")
  modified_dir <- path(final_archive_path, "MODIFIED")
  unchanged_dir <- path(final_archive_path, "UNCHANGED")
  
  dir_create(c(new_dir, modified_dir, unchanged_dir))
  
  # Copy files based on folder-level classification
  copy_results <- list()
  
  # Process NEW folders
  new_folders <- folder_analysis %>% filter(folder_action == "NEW")
  if(nrow(new_folders) > 0) {
    new_files <- file_summary %>%
      inner_join(new_folders %>% select(segment, deal), by = c("segment", "deal"))
    
    message("\nCopying ", nrow(new_files), " files from ", nrow(new_folders), " NEW folders...")
    
    new_copy_results <- copy_folder_files(new_files, source_path, new_dir)
    copy_results$new <- new_copy_results
  }
  
  # Process MODIFIED folders
  modified_folders <- folder_analysis %>% filter(folder_action == "MODIFIED")
  if(nrow(modified_folders) > 0) {
    modified_files <- file_summary %>%
      inner_join(modified_folders %>% select(segment, deal), by = c("segment", "deal"))
    
    message("\nCopying ", nrow(modified_files), " files from ", nrow(modified_folders), " MODIFIED folders...")
    
    modified_copy_results <- copy_folder_files(modified_files, source_path, modified_dir)
    copy_results$modified <- modified_copy_results
  }
  
  # Process UNCHANGED folders (create references)
  unchanged_folders <- folder_analysis %>% filter(folder_action == "UNCHANGED")
  if(nrow(unchanged_folders) > 0) {
    unchanged_files <- file_summary %>%
      inner_join(unchanged_folders %>% select(segment, deal), by = c("segment", "deal"))
    
    message("\nCreating references for ", nrow(unchanged_files), " files from ", nrow(unchanged_folders), " unchanged folders...")
    
    # Create a reference file listing unchanged folder locations
    unchanged_ref <- unchanged_files %>%
      select(segment, deal, relative_path, file_name, size, modified_time, current_archive_date, first_seen_quarter) %>%
      arrange(segment, deal, file_name)
    
    write_csv(unchanged_ref, path(unchanged_dir, "unchanged_folder_references.csv"))
    copy_results$unchanged_count <- nrow(unchanged_files)
  }
  
  # Create consolidated folder summary
  folder_summary <- folder_analysis %>%
    mutate(
      final_archive_location = case_when(
        folder_action == "NEW" ~ path(new_dir, segment, deal),
        folder_action == "MODIFIED" ~ path(modified_dir, segment, deal),
        folder_action == "UNCHANGED" ~ "Referenced - see unchanged_folder_references.csv"
      )
    ) %>%
    arrange(segment, deal)
  
  write_csv(folder_summary, path(final_archive_path, paste0(quarter_id, "_folder_summary.csv")))
  
  message("\n=== Consolidation Complete ===")
  message("Folder summary saved to: ", path(final_archive_path, paste0(quarter_id, "_folder_summary.csv")))
  
  return(list(
    folder_analysis = folder_analysis,
    copy_results = copy_results,
    final_archive_path = final_archive_path
  ))
}

#' Copy files for a folder-level archive
#'
#' @param files_df Data frame with file information
#' @param source_path Base source path
#' @param dest_base Destination base directory
#' @return Data frame with copy results
copy_folder_files <- function(files_df, source_path, dest_base) {
  
  copy_results <- map_dfr(1:nrow(files_df), function(i) {
    file_row <- files_df[i, ]
    
    source_file <- path(source_path, file_row$relative_path)
    dest_dir <- path(dest_base, file_row$segment, file_row$deal)
    dest_file <- path(dest_dir, file_row$file_name)
    
    # Create destination directory
    dir_create(dest_dir)
    
    # Copy file
    copy_success <- tryCatch({
      file_copy(source_file, dest_file, overwrite = TRUE)
      TRUE
    }, error = function(e) {
      warning("Failed to copy ", source_file, ": ", e$message)
      FALSE
    })
    
    tibble(
      segment = file_row$segment,
      deal = file_row$deal,
      file_name = file_row$file_name,
      source_file = source_file,
      dest_file = dest_file,
      copy_success = copy_success
    )
  })
  
  success_count <- sum(copy_results$copy_success)
  fail_count <- sum(!copy_results$copy_success)
  
  message("  Success: ", success_count, " | Failed: ", fail_count)
  
  return(copy_results)
}

#' Interactive Folder Review
#'
#' Review folder classifications and optionally reclassify before consolidation
#'
#' @param staging_path Path to staging directory
#' @export
review_folder_classifications <- function(staging_path) {
  quarter_id <- path_file(staging_path)
  summary_file <- path(staging_path, paste0(quarter_id, "_file_summary.csv"))
  
  file_summary <- read_csv(summary_file, show_col_types = FALSE)
  
  folder_analysis <- file_summary %>%
    group_by(segment, deal) %>%
    summarise(
      total_files = n(),
      new_count = sum(status == "NEW", na.rm = TRUE),
      modified_count = sum(status == "MODIFIED", na.rm = TRUE),
      renamed_count = sum(status == "RENAMED", na.rm = TRUE),
      reintroduced_count = sum(status == "REINTRODUCED", na.rm = TRUE),
      unchanged_count = sum(status == "UNCHANGED", na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      folder_action = case_when(
        modified_count > 0 | renamed_count > 0 ~ "MODIFIED",
        new_count > 0 | reintroduced_count > 0 ~ "NEW",
        TRUE ~ "UNCHANGED"
      )
    )
  
  # Display summary
  cat("\n=== Folder Classification Summary ===\n")
  print(table(folder_analysis$folder_action))
  
  cat("\n=== Folders with Mixed Changes ===\n")
  mixed_folders <- folder_analysis %>%
    filter((new_count > 0 & (modified_count > 0 | renamed_count > 0)) |
           (unchanged_count > 0 & (new_count > 0 | modified_count > 0)))
  
  if(nrow(mixed_folders) > 0) {
    print(mixed_folders)
  } else {
    cat("No folders with mixed changes.\n")
  }
  
  return(folder_analysis)
}
