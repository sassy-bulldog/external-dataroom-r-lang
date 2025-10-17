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
          size = as.numeric(file_info$size),
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
      renamed_files = tibble(),
      reintroduced_files = tibble(),
      unchanged_files = tibble(),
      removed_files = tibble(),
      summary = list(
        new_count = nrow(current_metadata$files),
        modified_count = 0,
        renamed_count = 0,
        reintroduced_count = 0,
        unchanged_count = 0,
        removed_count = 0
      )
    ))
  }
  
  current_files <- current_metadata$files
  
  # Handle previous files: include both active and previously removed files
  # Previous files might have status field indicating if they were removed in earlier quarters
  if(!is.null(previous_metadata$files) && length(previous_metadata$files) > 0) {
    previous_files_df <- as_tibble(previous_metadata$files)
    
    if("status" %in% names(previous_files_df)) {
      previous_active <- previous_files_df %>% 
        filter(is.na(status) | status != "removed")
      previous_removed <- previous_files_df %>% 
        filter(!is.na(status) & status == "removed")
    } else {
      previous_active <- previous_files_df
      previous_removed <- tibble()
    }
  } else {
    previous_active <- tibble()
    previous_removed <- tibble()
  }
  
  # Create comparison keys for content matching
  current_files <- current_files %>%
    mutate(content_key = paste(md5_hash, size, sep = "|"))
  
  previous_active <- previous_active %>%
    mutate(content_key = paste(md5_hash, size, sep = "|"))
  
  # 1. UNCHANGED: Exact content match (md5_hash + size) at same path
  unchanged_files <- tibble()
  if(all(c("relative_path", "content_key") %in% names(previous_active))) {
    unchanged_files <- current_files %>%
      inner_join(previous_active, by = c("relative_path", "content_key"), suffix = c("", "_prev")) %>%
      select(all_of(names(current_files)[names(current_files) != "content_key"]))
  }
  
  # 2. MODIFIED: Same path, different content
  modified_files <- tibble()
  if("relative_path" %in% names(previous_active)) {
    modified_files <- current_files %>%
      inner_join(previous_active, by = "relative_path", suffix = c("", "_prev")) %>%
      filter(content_key != content_key_prev) %>%
      select(all_of(names(current_files)[names(current_files) != "content_key"]))
  }
  
  # 3. Files at new paths (potential new, renamed, or reintroduced)
  files_at_new_paths <- current_files %>%
    anti_join(previous_active, by = "relative_path")
  
  # 4. RENAMED: Same content (md5_hash + size), different path
  renamed_files <- tibble()
  reintroduced_files <- tibble()
  
  if(nrow(files_at_new_paths) > 0) {
    # Files that were at old paths but not at current paths (candidates for rename source)
    files_at_old_paths <- previous_active %>%
      anti_join(current_files, by = "relative_path")
    
    # Primary match: exact content match (md5_hash + size)
    exact_content_matches <- tibble()
    if("content_key" %in% names(files_at_new_paths) && "content_key" %in% names(files_at_old_paths)) {
      exact_content_matches <- files_at_new_paths %>%
        inner_join(files_at_old_paths, by = "content_key", suffix = c("", "_prev"), relationship = "many-to-many") %>%
        mutate(
          change_type = "renamed",
          previous_path = relative_path_prev,
          match_confidence = "exact_content"
        )
    }

    renamed_files <- exact_content_matches
    
    # Check for reintroduced files (content matches previously removed files)
    if(nrow(previous_removed) > 0 && "md5_hash" %in% names(previous_removed) && "size" %in% names(previous_removed)) {
      previous_removed <- previous_removed %>%
        mutate(content_key = paste(md5_hash, size, sep = "|"))
      
      remaining_new_paths <- files_at_new_paths %>%
        anti_join(renamed_files, by = "relative_path")
      
      if(nrow(remaining_new_paths) > 0) {
        reintroduced_matches <- tibble()
        if("content_key" %in% names(previous_removed) && "content_key" %in% names(remaining_new_paths)) {
          reintroduced_matches <- remaining_new_paths %>%
            inner_join(previous_removed, by = "content_key", suffix = c("", "_removed")) %>%
            mutate(
              change_type = "reintroduced",
              first_removed_quarter = if("first_removed_quarter" %in% names(previous_removed)) first_removed_quarter_removed else NA_character_,
              original_path = relative_path_removed
            ) %>%
            select(all_of(c(names(current_files)[names(current_files) != "content_key"], 
                           "change_type", "first_removed_quarter", "original_path")))
        }
        
        reintroduced_files <- reintroduced_matches
      }
    }
  }
  
  # 5. NEW: Files that don't match any previous content
  new_files <- files_at_new_paths
  if(nrow(renamed_files) > 0 && "relative_path" %in% names(renamed_files)) {
    new_files <- new_files %>% anti_join(renamed_files, by = "relative_path")
  }
  if(nrow(reintroduced_files) > 0 && "relative_path" %in% names(reintroduced_files)) {
    new_files <- new_files %>% anti_join(reintroduced_files, by = "relative_path")
  }
  
  # 6. REMOVED: Carry forward previously removed + newly removed
  # Newly removed files (were active, now missing)
  newly_removed <- previous_active %>%
    anti_join(current_files, by = "relative_path")
  
  # Only filter out renamed files if there are any
  if(nrow(renamed_files) > 0 && "previous_path" %in% names(renamed_files)) {
    newly_removed <- newly_removed %>%
      anti_join(renamed_files, by = c("relative_path" = "previous_path"))
  }
  
  newly_removed <- newly_removed %>%
    mutate(
      status = "removed",
      first_removed_quarter = current_metadata$summary$snapshot_id
    )
  
  # Carry forward previously removed files (still missing)
  still_removed <- tibble()
  if(nrow(previous_removed) > 0 && nrow(reintroduced_files) == 0) {
    still_removed <- previous_removed %>%
      mutate(
        status = "removed",
        first_removed_quarter = if("first_removed_quarter" %in% names(previous_removed)) first_removed_quarter else current_metadata$summary$snapshot_id
      ) %>%
      select(any_of(names(newly_removed)))
  } else if(nrow(previous_removed) > 0 && nrow(reintroduced_files) > 0) {
    still_removed <- previous_removed
    if("content_key" %in% names(reintroduced_files)) {
      still_removed <- still_removed %>%
        anti_join(reintroduced_files, by = "content_key")
    }
    still_removed <- still_removed %>%
      mutate(
        status = "removed",
        first_removed_quarter = if("first_removed_quarter" %in% names(previous_removed)) first_removed_quarter else current_metadata$summary$snapshot_id
      ) %>%
      select(any_of(names(newly_removed)))
  }
  
  removed_files <- bind_rows(newly_removed, still_removed)
  
  summary_info <- list(
    new_count = nrow(new_files),
    modified_count = nrow(modified_files),
    renamed_count = nrow(renamed_files),
    reintroduced_count = nrow(reintroduced_files),
    unchanged_count = nrow(unchanged_files),
    removed_count = nrow(removed_files)
  )
  
  message("Comparison complete:")
  message("  New files: ", summary_info$new_count)
  message("  Modified files: ", summary_info$modified_count)
  message("  Renamed files: ", summary_info$renamed_count)
  message("  Reintroduced files: ", summary_info$reintroduced_count)
  message("  Unchanged files: ", summary_info$unchanged_count)
  message("  Removed files: ", summary_info$removed_count)
  
  return(list(
    new_files = new_files,
    modified_files = modified_files,
    renamed_files = renamed_files,
    reintroduced_files = reintroduced_files,
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
  
  # Create current snapshot metadata (active files only)
  current_metadata <- create_snapshot_metadata(
    source_path = source_path,
    snapshot_id = snapshot_id,
    metadata_file = current_metadata_file,
    classification_pattern = classification_pattern,
    exclude_patterns = exclude_patterns
  )
  
  # Find most recent previous snapshot (excluding current snapshot)
  previous_metadata <- NULL
  if(dir_exists(archive_root)) {
    existing_snapshots <- dir_ls(archive_root, type = "directory") %>%
      path_file() %>%
      setdiff(snapshot_id) %>%  # Exclude current snapshot
      sort(decreasing = TRUE)
    
    if(length(existing_snapshots) > 0) {
      previous_snapshot_id <- existing_snapshots[1]
      previous_metadata_file <- path(archive_root, previous_snapshot_id, paste0(previous_snapshot_id, "_metadata.json"))
      previous_metadata <- load_snapshot_metadata(previous_metadata_file)
      message("Comparing against previous snapshot: ", previous_snapshot_id)
    } else {
      message("No previous snapshots found - all files will be marked as NEW")
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
  
  # Create enhanced metadata that includes removed files for persistence
  if(exists("comparison_result")) {
    # Safely combine active files with removed files for complete metadata
    file_components <- list()
    
    if(nrow(comparison_result$new_files) > 0) {
      file_components$new <- comparison_result$new_files %>% mutate(status = NA_character_)
    }
    if(nrow(comparison_result$modified_files) > 0) {
      file_components$modified <- comparison_result$modified_files %>% mutate(status = NA_character_)
    }
    if(nrow(comparison_result$renamed_files) > 0) {
      file_components$renamed <- comparison_result$renamed_files %>% mutate(status = NA_character_)
    }
    if(nrow(comparison_result$reintroduced_files) > 0) {
      file_components$reintroduced <- comparison_result$reintroduced_files %>% mutate(status = NA_character_)
    }
    if(nrow(comparison_result$unchanged_files) > 0) {
      file_components$unchanged <- comparison_result$unchanged_files %>% mutate(status = NA_character_)
    }
    if(nrow(comparison_result$removed_files) > 0) {
      file_components$removed <- comparison_result$removed_files  # already has status field
    }
    
    # Combine all non-empty components
    if(length(file_components) > 0) {
      all_files_with_status <- bind_rows(file_components)
    } else {
      all_files_with_status <- current_metadata$files %>% mutate(status = NA_character_)
    }
    
    # Update current metadata to include all files (active + removed)
    current_metadata$files <- all_files_with_status
    
    # Re-save the enhanced metadata
    write_json(current_metadata, current_metadata_file, pretty = TRUE, auto_unbox = TRUE)
    
    # Create summary CSV (active files only for display)
    summary_components <- list()
    
    if(nrow(comparison_result$new_files) > 0) {
      summary_components$new <- comparison_result$new_files %>% mutate(status = "NEW")
    }
    if(nrow(comparison_result$modified_files) > 0) {
      summary_components$modified <- comparison_result$modified_files %>% mutate(status = "MODIFIED")
    }
    if(nrow(comparison_result$renamed_files) > 0) {
      summary_components$renamed <- comparison_result$renamed_files %>% mutate(status = "RENAMED")
    }
    if(nrow(comparison_result$reintroduced_files) > 0) {
      summary_components$reintroduced <- comparison_result$reintroduced_files %>% mutate(status = "REINTRODUCED")
    }
    if(nrow(comparison_result$unchanged_files) > 0) {
      summary_components$unchanged <- comparison_result$unchanged_files %>% mutate(status = "UNCHANGED")
    }
    
    if(length(summary_components) > 0) {
      summary_df <- bind_rows(summary_components) %>%
        select(status, category_1, category_2, relative_path, file_name, size, modified_time) %>%
        arrange(status, category_1, category_2, relative_path)
      
      write_csv(summary_df, path(current_staging_path, paste0(snapshot_id, "_file_summary.csv")))
    }
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