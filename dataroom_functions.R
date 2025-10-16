#' Incremental Data Room Archive Functions
#' 
#' This file contains generalized functionality for creating incremental archives
#' of any source folder structure, comparing against previous snapshots, and
#' maintaining efficient metadata for fast comparisons.

library(fs)
library(tidyverse)
library(stringr)
library(lubridate)
library(jsonlite)
library(digest)

#' Create or Update Snapshot Metadata
#'
#' Creates a JSON metadata file containing file hashes, timestamps, and structure
#' information for quick comparison without full filesystem scans.
#'
#' @param source_path Path to scan for files
#' @param snapshot_id Unique identifier for this snapshot (e.g., "2025Q2", "monthly_2025_10")
#' @param metadata_file Path where JSON metadata should be saved
#' @param classification_pattern Regex pattern to extract classification info from paths
#' @param exclude_patterns Vector of regex patterns for paths to exclude
#' @return List containing metadata information
#' @export
create_snapshot_metadata <- function(
  source_path,
  snapshot_id,
  metadata_file,
  classification_pattern = "^([^/]+)/([^/]+)/",
  exclude_patterns = c("Working Files", "\\.tmp$", "~\\$")
) {
  
  message("Creating snapshot metadata for: ", source_path)
  
  # Get all files recursively
  all_files <- dir_ls(source_path, recurse = TRUE, type = "file")
  
  # Apply exclusion patterns
  for(pattern in exclude_patterns) {
    all_files <- all_files[!grepl(pattern, all_files, ignore.case = TRUE)]
  }
  
  if(length(all_files) == 0) {
    warning("No files found in source path after applying exclusions")
    return(list(files = list(), summary = list()))
  }
  
  message("Processing ", length(all_files), " files...")
  
  # Create file metadata in parallel chunks
  process_chunk <- function(file_chunk) {
    map_dfr(file_chunk, function(file_path) {
      tryCatch({
        file_info <- file_info(file_path)
        rel_path <- path_rel(file_path, source_path)
        
        # Extract classification info using regex
        classification <- str_match(rel_path, classification_pattern)
        
        tibble(
          full_path = as.character(file_path),
          relative_path = as.character(rel_path),
          file_name = path_file(file_path),
          size = file_info$size,
          modified_time = as.character(file_info$modification_time),
          md5_hash = digest(file = file_path, algo = "md5"),
          category_1 = if(!is.na(classification[2])) classification[2] else "uncategorized",
          category_2 = if(!is.na(classification[3])) classification[3] else "uncategorized",
          directory = path_dir(rel_path)
        )
      }, error = function(e) {
        warning("Error processing file: ", file_path, " - ", e$message)
        NULL
      })
    })
  }
  
  # Process in chunks for better memory management
  chunk_size <- min(100, length(all_files))
  file_chunks <- split(all_files, ceiling(seq_along(all_files) / chunk_size))
  
  file_metadata <- map_dfr(file_chunks, process_chunk)
  
  # Create summary statistics
  summary_stats <- list(
    snapshot_id = snapshot_id,
    created_at = as.character(Sys.time()),
    source_path = source_path,
    total_files = nrow(file_metadata),
    total_size = sum(file_metadata$size, na.rm = TRUE),
    categories = file_metadata %>% 
      count(category_1, category_2, name = "file_count") %>%
      arrange(category_1, category_2),
    file_types = file_metadata %>%
      mutate(extension = path_ext(file_name)) %>%
      count(extension, name = "count") %>%
      arrange(desc(count))
  )
  
  # Create complete metadata object
  metadata <- list(
    summary = summary_stats,
    files = file_metadata
  )
  
  # Save to JSON file
  dir_create(path_dir(metadata_file))
  write_json(metadata, metadata_file, pretty = TRUE, auto_unbox = TRUE)
  
  message("Metadata saved to: ", metadata_file)
  return(metadata)
}

#' Load Snapshot Metadata
#'
#' Loads previously saved snapshot metadata from JSON file
#'
#' @param metadata_file Path to JSON metadata file
#' @return List containing metadata information or NULL if file doesn't exist
#' @export
load_snapshot_metadata <- function(metadata_file) {
  if(!file_exists(metadata_file)) {
    return(NULL)
  }
  
  tryCatch({
    metadata <- read_json(metadata_file, simplifyVector = TRUE)
    # Convert files back to tibble if it exists
    if(!is.null(metadata$files) && length(metadata$files) > 0) {
      metadata$files <- as_tibble(metadata$files)
    }
    return(metadata)
  }, error = function(e) {
    warning("Error loading metadata file: ", metadata_file, " - ", e$message)
    return(NULL)
  })
}

#' Compare Snapshots and Identify Changes
#'
#' Compares current source against previous snapshot metadata to identify
#' new, modified, and unchanged files
#'
#' @param current_metadata Current snapshot metadata
#' @param previous_metadata Previous snapshot metadata (can be NULL)
#' @return List containing categorized file information
#' @export
compare_snapshots <- function(current_metadata, previous_metadata = NULL) {
  
  if(is.null(previous_metadata) || is.null(previous_metadata$files) || nrow(previous_metadata$files) == 0) {
    message("No previous snapshot found - all files will be treated as new")
    return(list(
      new_files = current_metadata$files,
      modified_files = tibble(),
      unchanged_files = tibble(),
      removed_files = tibble(),
      summary = list(
        new_count = nrow(current_metadata$files),
        modified_count = 0,
        unchanged_count = 0,
        removed_count = 0
      )
    ))
  }
  
  current_files <- current_metadata$files
  previous_files <- previous_metadata$files
  
  # Create comparison keys
  current_files <- current_files %>%
    mutate(comparison_key = paste(relative_path, size, modified_time, sep = "|"))
  
  previous_files <- previous_files %>%
    mutate(comparison_key = paste(relative_path, size, modified_time, sep = "|"))
  
  # Identify file categories
  unchanged_files <- current_files %>%
    inner_join(previous_files, by = "comparison_key", suffix = c("", "_prev")) %>%
    select(all_of(names(current_files)[names(current_files) != "comparison_key"]))
  
  # Files that exist in current but not in previous (by path)
  potential_new <- current_files %>%
    anti_join(previous_files, by = "relative_path")
  
  # Files that exist in both locations but with different content
  potential_modified <- current_files %>%
    inner_join(previous_files, by = "relative_path", suffix = c("", "_prev")) %>%
    filter(comparison_key != comparison_key_prev) %>%
    select(all_of(names(current_files)[names(current_files) != "comparison_key"]))
  
  # Check for renamed files (same content, different path)
  renamed_files <- tibble()
  if(nrow(potential_new) > 0 && nrow(previous_files) > 0) {
    # Match by md5_hash and size to find potential renames
    potential_renames <- potential_new %>%
      inner_join(
        previous_files %>% 
          anti_join(current_files, by = "relative_path"),
        by = c("md5_hash", "size"),
        suffix = c("", "_prev")
      ) %>%
      mutate(
        change_type = "renamed",
        previous_path = relative_path_prev
      )
    
    renamed_files <- potential_renames
    
    # Remove renamed files from potential_new
    potential_new <- potential_new %>%
      anti_join(potential_renames, by = c("relative_path", "md5_hash", "size"))
  }
  
  # Files that existed previously but not in current
  removed_files <- previous_files %>%
    anti_join(current_files, by = "relative_path") %>%
    anti_join(renamed_files, by = c("relative_path" = "previous_path"))
  
  summary_info <- list(
    new_count = nrow(potential_new),
    modified_count = nrow(potential_modified),
    renamed_count = nrow(renamed_files),
    unchanged_count = nrow(unchanged_files),
    removed_count = nrow(removed_files)
  )
  
  message("Comparison complete:")
  message("  New files: ", summary_info$new_count)
  message("  Modified files: ", summary_info$modified_count)
  message("  Renamed files: ", summary_info$renamed_count)
  message("  Unchanged files: ", summary_info$unchanged_count)
  message("  Removed files: ", summary_info$removed_count)
  
  return(list(
    new_files = potential_new,
    modified_files = potential_modified,
    renamed_files = renamed_files,
    unchanged_files = unchanged_files,
    removed_files = removed_files,
    summary = summary_info
  ))
}

#' Create Incremental Archive
#'
#' Main function to create an incremental archive by comparing current source
#' against previous snapshots and copying only new/changed files
#'
#' @param archive_config List containing archive configuration
#' @return List containing archive results and metadata
#' @export
create_incremental_archive <- function(archive_config) {
  
  # Validate required config parameters
  required_params <- c("snapshot_id", "source_path", "archive_root", "staging_root")
  missing_params <- setdiff(required_params, names(archive_config))
  if(length(missing_params) > 0) {
    stop("Missing required parameters: ", paste(missing_params, collapse = ", "))
  }
  
  # Extract configuration
  snapshot_id <- archive_config$snapshot_id
  source_path <- archive_config$source_path
  archive_root <- archive_config$archive_root
  staging_root <- archive_config$staging_root
  archive_name <- archive_config$archive_name %||% "data_archive"
  classification_pattern <- archive_config$classification_pattern %||% "^([^/]+)/([^/]+)/"
  exclude_patterns <- archive_config$exclude_patterns %||% c("Working Files", "\\.tmp$", "~\\$")
  
  message("=== Starting Incremental Archive Process ===")
  message("Snapshot ID: ", snapshot_id)
  message("Source Path: ", source_path)
  message("Archive Root: ", archive_root)
  
  # Setup paths
  current_staging_path <- path(staging_root, snapshot_id)
  current_archive_path <- path(archive_root, snapshot_id)
  current_metadata_file <- path(current_staging_path, paste0(snapshot_id, "_metadata.json"))
  
  dir_create(current_staging_path)
  
  # Create current snapshot metadata
  current_metadata <- create_snapshot_metadata(
    source_path = source_path,
    snapshot_id = snapshot_id,
    metadata_file = current_metadata_file,
    classification_pattern = classification_pattern,
    exclude_patterns = exclude_patterns
  )
  
  # Find most recent previous snapshot
  previous_metadata <- NULL
  if(dir_exists(archive_root)) {
    existing_snapshots <- dir_ls(archive_root, type = "directory") %>%
      path_file() %>%
      sort(decreasing = TRUE)
    
    if(length(existing_snapshots) > 0) {
      previous_snapshot_id <- existing_snapshots[1]
      previous_metadata_file <- path(archive_root, previous_snapshot_id, paste0(previous_snapshot_id, "_metadata.json"))
      previous_metadata <- load_snapshot_metadata(previous_metadata_file)
      message("Comparing against previous snapshot: ", previous_snapshot_id)
    }
  }
  
  # Compare snapshots
  comparison_result <- compare_snapshots(current_metadata, previous_metadata)
  
  # Create output directories
  new_files_dir <- path(current_staging_path, "NEW")
  modified_files_dir <- path(current_staging_path, "MODIFIED")
  unchanged_files_dir <- path(current_staging_path, "UNCHANGED")
  
  dir_create(c(new_files_dir, modified_files_dir, unchanged_files_dir))
  
  # Copy files based on classification
  copy_operations <- list()
  
  # Process new files
  if(nrow(comparison_result$new_files) > 0) {
    message("Copying ", nrow(comparison_result$new_files), " new files...")
    new_copy_ops <- comparison_result$new_files %>%
      mutate(
        source_file = full_path,
        dest_dir = path(new_files_dir, category_1, category_2),
        dest_file = path(dest_dir, file_name),
        operation_type = "new"
      )
    copy_operations <- c(copy_operations, list(new_copy_ops))
  }
  
  # Process modified files
  if(nrow(comparison_result$modified_files) > 0) {
    message("Copying ", nrow(comparison_result$modified_files), " modified files...")
    modified_copy_ops <- comparison_result$modified_files %>%
      mutate(
        source_file = full_path,
        dest_dir = path(modified_files_dir, category_1, category_2),
        dest_file = path(dest_dir, file_name),
        operation_type = "modified"
      )
    copy_operations <- c(copy_operations, list(modified_copy_ops))
  }
  
  # Create reference links for unchanged files
  if(nrow(comparison_result$unchanged_files) > 0) {
    message("Creating references for ", nrow(comparison_result$unchanged_files), " unchanged files...")
    unchanged_refs <- comparison_result$unchanged_files %>%
      mutate(
        reference_path = if(!is.null(previous_metadata)) {
          path(archive_root, previous_metadata$summary$snapshot_id, "archive", category_1, category_2, file_name)
        } else {
          NA_character_
        },
        dest_dir = path(unchanged_files_dir, category_1, category_2),
        operation_type = "reference"
      )
    
    # Save reference information
    write_csv(unchanged_refs, path(current_staging_path, "unchanged_file_references.csv"))
  }
  
  # Execute copy operations
  if(length(copy_operations) > 0) {
    all_copy_ops <- bind_rows(copy_operations)
    
    # Create destination directories
    unique_dirs <- unique(all_copy_ops$dest_dir)
    walk(unique_dirs, ~ dir_create(.x))
    
    # Perform copies
    copy_results <- all_copy_ops %>%
      mutate(
        copy_success = map2_lgl(source_file, dest_file, ~ {
          tryCatch({
            file_copy(.x, .y, overwrite = TRUE)
            TRUE
          }, error = function(e) {
            warning("Failed to copy: ", .x, " -> ", .y, " Error: ", e$message)
            FALSE
          })
        })
      )
    
    failed_copies <- copy_results %>%
      filter(!copy_success)
    
    if(nrow(failed_copies) > 0) {
      warning("Failed to copy ", nrow(failed_copies), " files")
      write_csv(failed_copies, path(current_staging_path, "failed_copies.csv"))
    }
    
  } else {
    copy_results <- tibble()
  }
  
  # Create comprehensive report
  archive_report <- list(
    snapshot_id = snapshot_id,
    created_at = as.character(Sys.time()),
    source_path = source_path,
    archive_config = archive_config,
    comparison_summary = comparison_result$summary,
    files_copied = if(length(copy_operations) > 0) nrow(copy_results %>% filter(copy_success)) else 0,
    files_failed = if(length(copy_operations) > 0) nrow(copy_results %>% filter(!copy_success)) else 0,
    metadata_file = current_metadata_file,
    staging_path = current_staging_path
  )
  
  # Save archive report
  write_json(archive_report, path(current_staging_path, paste0(snapshot_id, "_archive_report.json")), 
             pretty = TRUE, auto_unbox = TRUE)
  
  # Create summary CSV
  if(exists("comparison_result")) {
    summary_df <- bind_rows(
      comparison_result$new_files %>% mutate(status = "NEW"),
      comparison_result$modified_files %>% mutate(status = "MODIFIED"),
      comparison_result$unchanged_files %>% mutate(status = "UNCHANGED")
    ) %>%
      select(status, category_1, category_2, relative_path, file_name, size, modified_time) %>%
      arrange(status, category_1, category_2, relative_path)
    
    write_csv(summary_df, path(current_staging_path, paste0(snapshot_id, "_file_summary.csv")))
  }
  
  message("=== Archive Process Complete ===")
  message("Staging location: ", current_staging_path)
  message("Files processed: ", current_metadata$summary$total_files)
  message("Files copied: ", archive_report$files_copied)
  
  return(archive_report)
}

#' Archive Multiple Sources
#'
#' Process multiple source directories in a single operation
#'
#' @param multi_config List of archive configurations
#' @param global_snapshot_id Optional global snapshot ID to use for all archives
#' @return List of archive results
#' @export
create_multiple_archives <- function(multi_config, global_snapshot_id = NULL) {
  
  if(!is.null(global_snapshot_id)) {
    multi_config <- map(multi_config, ~ {
      .x$snapshot_id <- global_snapshot_id
      .x
    })
  }
  
  message("=== Processing Multiple Archives ===")
  message("Number of archives: ", length(multi_config))
  
  results <- map(multi_config, create_incremental_archive)
  names(results) <- map_chr(multi_config, ~ .x$archive_name %||% "unnamed")
  
  # Create consolidated report
  consolidated_report <- list(
    created_at = as.character(Sys.time()),
    global_snapshot_id = global_snapshot_id,
    total_archives = length(results),
    individual_results = results,
    summary = list(
      total_files_processed = sum(map_dbl(results, ~ .x$comparison_summary$new_count + 
                                                    .x$comparison_summary$modified_count + 
                                                    .x$comparison_summary$unchanged_count)),
      total_files_copied = sum(map_dbl(results, ~ .x$files_copied)),
      total_new_files = sum(map_dbl(results, ~ .x$comparison_summary$new_count)),
      total_modified_files = sum(map_dbl(results, ~ .x$comparison_summary$modified_count))
    )
  )
  
  message("=== Multiple Archive Process Complete ===")
  message("Total files processed: ", consolidated_report$summary$total_files_processed)
  message("Total files copied: ", consolidated_report$summary$total_files_copied)
  
  return(consolidated_report)
}