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
          segment = if(!is.na(classification[2])) classification[2] else "uncategorized",
          deal = if(!is.na(classification[3])) classification[3] else "uncategorized",
          directory = path_dir(rel_path),
          current_archive_date = snapshot_id,
          first_seen_quarter = snapshot_id,
          last_archived_quarter = snapshot_id  # New files are archived in current quarter
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
      count(segment, deal, name = "file_count") %>%
      arrange(segment, deal),
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

#' Mark Duplicate Files
#'
#' Identifies files with duplicate content (same md5_hash and size) and marks them.
#' The primary file (earliest modified_time, or shortest path if tied) is not marked.
#' All other duplicates are marked with is_duplicate=TRUE and duplicate_of pointing to primary.
#'
#' @param files_df Tibble containing file metadata with content_key, modified_time, relative_path
#' @return Tibble with added columns: is_duplicate (logical) and duplicate_of (character)
#' @export
mark_duplicates <- function(files_df) {
  if(nrow(files_df) == 0 || !"content_key" %in% names(files_df)) {
    return(files_df %>% mutate(is_duplicate = FALSE, duplicate_of = NA_character_))
  }
  
  # Group by content_key to find duplicates
  files_with_dup_info <- files_df %>%
    group_by(content_key) %>%
    mutate(
      duplicate_count = n(),
      # Sort within group: earliest modified_time, then shortest path
      sort_key = paste(modified_time, str_length(relative_path), relative_path, sep = "|")
    ) %>%
    arrange(content_key, sort_key) %>%
    mutate(
      # First file in each group is the primary
      is_primary = row_number() == 1,
      # Primary file path for this content
      primary_path = first(relative_path)
    ) %>%
    ungroup() %>%
    mutate(
      is_duplicate = duplicate_count > 1 & !is_primary,
      duplicate_of = if_else(is_duplicate, primary_path, NA_character_)
    ) %>%
    select(-duplicate_count, -sort_key, -is_primary, -primary_path)
  
  return(files_with_dup_info)
}

#' Calculate Fuzzy Match Score for Potential Renamed-and-Modified Files
#'
#' Compares two files based on characteristics other than content to determine
#' if they might be the same file that was renamed and modified.
#'
#' @param new_file Single row tibble with file metadata
#' @param removed_file Single row tibble with file metadata
#' @return Numeric score (0-100) indicating match likelihood
#' @export
calculate_fuzzy_match_score <- function(new_file, removed_file) {
  score <- 0
  max_score <- 100
  
  # 1. File extension match (25 points)
  new_ext <- tolower(path_ext(new_file$file_name))
  old_ext <- tolower(path_ext(removed_file$file_name))
  if(new_ext == old_ext && nchar(new_ext) > 0) {
    score <- score + 25
  }
  
  # 2. File name similarity using string distance (30 points)
  new_name <- tolower(path_file(new_file$file_name))
  old_name <- tolower(path_file(removed_file$file_name))
  
  # Calculate Levenshtein distance normalized by max length
  max_len <- max(nchar(new_name), nchar(old_name))
  if(max_len > 0) {
    distance <- adist(new_name, old_name)[1,1]
    similarity <- 1 - (distance / max_len)
    score <- score + (similarity * 30)
  }
  
  # 3. Size similarity (20 points) - allow up to 20% difference
  if(!is.na(new_file$size) && !is.na(removed_file$size) && 
     new_file$size > 0 && removed_file$size > 0) {
    size_ratio <- min(new_file$size, removed_file$size) / max(new_file$size, removed_file$size)
    if(size_ratio >= 0.8) {  # Within 20% of each other
      score <- score + (size_ratio * 20)
    }
  }
  
  # 4. Directory similarity (15 points)
  new_dir <- tolower(path_dir(new_file$relative_path))
  old_dir <- tolower(path_dir(removed_file$relative_path))
  
  # Check if directories share common path components
  new_parts <- str_split(new_dir, "/")[[1]]
  old_parts <- str_split(old_dir, "/")[[1]]
  common_parts <- length(intersect(new_parts, old_parts))
  max_parts <- max(length(new_parts), length(old_parts))
  if(max_parts > 0) {
    dir_similarity <- common_parts / max_parts
    score <- score + (dir_similarity * 15)
  }
  
  # 5. Modified time proximity (10 points) - files modified within 30 days
  if(!is.na(new_file$modified_time) && !is.na(removed_file$modified_time)) {
    tryCatch({
      new_time <- as.POSIXct(new_file$modified_time)
      old_time <- as.POSIXct(removed_file$modified_time)
      days_diff <- abs(as.numeric(difftime(new_time, old_time, units = "days")))
      if(days_diff <= 30) {
        time_score <- 10 * (1 - (days_diff / 30))
        score <- score + time_score
      }
    }, error = function(e) {
      # Ignore date parsing errors
    })
  }
  
  return(round(score, 2))
}

#' Identify Potential Renamed-and-Modified File Pairs
#'
#' Finds pairs of NEW and REMOVED files that may actually be the same file
#' that was both renamed and modified. Uses fuzzy matching based on file
#' characteristics.
#'
#' @param new_files Tibble of new files
#' @param removed_files Tibble of removed files
#' @param threshold Minimum match score (0-100) to flag as potential match (default 60)
#' @return List with new_files and removed_files tibbles with added suggestion columns
#' @export
identify_potential_rename_modify <- function(new_files, removed_files, threshold = 60) {
  
  # Initialize suggestion columns
  new_files <- new_files %>%
    mutate(
      potential_rename_modify = FALSE,
      suggested_original_file = NA_character_,
      match_confidence_score = NA_real_
    )
  
  removed_files <- removed_files %>%
    mutate(
      potential_rename_modify = FALSE,
      suggested_new_file = NA_character_,
      match_confidence_score = NA_real_
    )
  
  # If either set is empty, return with empty suggestions
  if(nrow(new_files) == 0 || nrow(removed_files) == 0) {
    return(list(new_files = new_files, removed_files = removed_files))
  }
  
  # Calculate scores for all pairs (don't filter by threshold yet)
  matches <- expand_grid(
    new_idx = 1:nrow(new_files),
    removed_idx = 1:nrow(removed_files)
  ) %>%
    rowwise() %>%
    mutate(
      score = calculate_fuzzy_match_score(
        new_files[new_idx, ],
        removed_files[removed_idx, ]
      )
    ) %>%
    ungroup() %>%
    arrange(desc(score))
  
  # For each new file, find best match. Always record the best candidate
  # and its score; only set potential_rename_modify to TRUE when the score >= threshold.
  for(i in 1:nrow(new_files)) {
    best_match <- matches %>%
      filter(new_idx == i) %>%
      slice_max(score, n = 1, with_ties = FALSE)

    if(nrow(best_match) > 0) {
      candidate_removed <- removed_files$relative_path[best_match$removed_idx]
      candidate_score <- best_match$score
      new_files$suggested_original_file[i] <- candidate_removed
      new_files$match_confidence_score[i] <- candidate_score
      if(candidate_score >= threshold) {
        new_files$potential_rename_modify[i] <- TRUE
      }
    }
  }

  # For each removed file, find best match. Record best candidate and score.
  for(i in 1:nrow(removed_files)) {
    best_match <- matches %>%
      filter(removed_idx == i) %>%
      slice_max(score, n = 1, with_ties = FALSE)

    if(nrow(best_match) > 0) {
      candidate_new <- new_files$relative_path[best_match$new_idx]
      candidate_score <- best_match$score
      removed_files$suggested_new_file[i] <- candidate_new
      removed_files$match_confidence_score[i] <- candidate_score
      if(candidate_score >= threshold) {
        removed_files$potential_rename_modify[i] <- TRUE
      }
    }
  }
  
  return(list(new_files = new_files, removed_files = removed_files))
}

#' Compare Snapshots and Identify Changes
#'
#' Compares current source against previous snapshot metadata to identify
#' new, modified, and unchanged files. Also detects duplicate content and
#' potential renamed-and-modified file pairs.
#'
#' @param current_metadata Current snapshot metadata
#' @param previous_metadata Previous snapshot metadata (can be NULL)
#' @param verbose Logical, whether to print progress messages (default TRUE)
#' @param fuzzy_match_threshold Minimum score (0-100) for flagging potential rename-modify pairs (default 80)
#' @return List containing categorized file information
#' @export
compare_snapshots <- function(current_metadata, previous_metadata = NULL, verbose = TRUE, fuzzy_match_threshold = 80) {
  
  if(is.null(previous_metadata) || is.null(previous_metadata$files) || nrow(previous_metadata$files) == 0) {
    if(verbose) message("No previous snapshot found - all files will be treated as new")
    
    # Mark duplicates in the new files
    new_files_with_dups <- mark_duplicates(current_metadata$files)
    dup_count <- sum(new_files_with_dups$is_duplicate, na.rm = TRUE)
    
    # Add fuzzy matching columns (even though there's nothing to match against)
    new_files_with_dups <- new_files_with_dups %>%
      mutate(
        potential_rename_modify = NA,
        suggested_original_file = NA_character_,
        match_confidence_score = NA_real_
      )
    
    return(list(
      new_files = new_files_with_dups,
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
        removed_count = 0,
        duplicate_count = dup_count
      )
    ))
  }
  
  # `current_metadata$files` may be an enhanced metadata blob that includes
  # previously removed files (status == "removed"). For comparisons we only
  # want the active files (those without `status == 'removed'`). Handle both
  # raw snapshot metadata and enhanced metadata here.
  current_files_raw <- current_metadata$files
  if(!is.null(current_files_raw) && "status" %in% names(current_files_raw)) {
    current_files <- current_files_raw %>%
      filter(is.na(status) | status != "removed")
  } else {
    current_files <- current_files_raw
  }
  
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
      mutate(
        first_seen_quarter = if("first_seen_quarter" %in% names(previous_active)) first_seen_quarter_prev else first_seen_quarter,
        last_archived_quarter = if("last_archived_quarter" %in% names(previous_active)) last_archived_quarter_prev else last_archived_quarter
      ) %>%
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
          match_confidence = "exact_content",
          first_seen_quarter = if("first_seen_quarter" %in% names(files_at_old_paths)) first_seen_quarter_prev else first_seen_quarter,
          last_archived_quarter = last_archived_quarter  # Renamed files are archived in current quarter (already set correctly)
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
            inner_join(previous_removed, by = "content_key", suffix = c("", "_removed"), relationship = "many-to-many") %>%
            mutate(
              change_type = "reintroduced",
              first_removed_quarter = if(any(str_detect(names(.), "_removed$"))) {
                if("first_removed_quarter_removed" %in% names(.)) first_removed_quarter_removed else NA_character_
              } else NA_character_,
              original_path = relative_path_removed,
              first_seen_quarter = if("first_seen_quarter_removed" %in% names(.)) first_seen_quarter_removed else first_seen_quarter,
              last_archived_quarter = last_archived_quarter  # Reintroduced files are archived in current quarter (already set correctly)
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
  
  # Mark duplicates in each category (for active files only)
  new_files <- mark_duplicates(new_files)
  modified_files <- mark_duplicates(modified_files)
  renamed_files <- mark_duplicates(renamed_files)
  reintroduced_files <- mark_duplicates(reintroduced_files)
  unchanged_files <- mark_duplicates(unchanged_files)
  
  # Add fuzzy matching columns to file types that don't get fuzzy matched
  # (so all file types have consistent columns for binding)
  modified_files <- modified_files %>%
    mutate(
      potential_rename_modify = NA,
      suggested_original_file = NA_character_,
      match_confidence_score = NA_real_
    )
  renamed_files <- renamed_files %>%
    mutate(
      potential_rename_modify = NA,
      suggested_original_file = NA_character_,
      match_confidence_score = NA_real_
    )
  reintroduced_files <- reintroduced_files %>%
    mutate(
      potential_rename_modify = NA,
      suggested_original_file = NA_character_,
      match_confidence_score = NA_real_
    )
  unchanged_files <- unchanged_files %>%
    mutate(
      potential_rename_modify = NA,
      suggested_original_file = NA_character_,
      match_confidence_score = NA_real_
    )
  
  # Count duplicates across all active files
  total_duplicates <- sum(
    sum(new_files$is_duplicate, na.rm = TRUE),
    sum(modified_files$is_duplicate, na.rm = TRUE),
    sum(renamed_files$is_duplicate, na.rm = TRUE),
    sum(reintroduced_files$is_duplicate, na.rm = TRUE),
    sum(unchanged_files$is_duplicate, na.rm = TRUE)
  )
  
  # Identify potential renamed-and-modified file pairs using fuzzy matching
  # This helps flag cases where a file was both renamed AND modified (so MD5 doesn't match)
  fuzzy_results <- identify_potential_rename_modify(new_files, removed_files, fuzzy_match_threshold)
  new_files <- fuzzy_results$new_files
  removed_files <- fuzzy_results$removed_files
  
  # Count potential rename-modify pairs for reporting
  potential_rename_modify_count <- sum(new_files$potential_rename_modify, na.rm = TRUE)
  
  summary_info <- list(
    new_count = nrow(new_files),
    modified_count = nrow(modified_files),
    renamed_count = nrow(renamed_files),
    reintroduced_count = nrow(reintroduced_files),
    unchanged_count = nrow(unchanged_files),
    removed_count = nrow(removed_files),
    duplicate_count = total_duplicates,
    potential_rename_modify_count = potential_rename_modify_count
  )
  
  if(verbose) {
    message("Comparison complete:")
    message("  New files: ", summary_info$new_count)
    message("  Modified files: ", summary_info$modified_count)
    message("  Renamed files: ", summary_info$renamed_count)
    message("  Reintroduced files: ", summary_info$reintroduced_count)
    message("  Unchanged files: ", summary_info$unchanged_count)
    message("  Removed files: ", summary_info$removed_count)
    if(total_duplicates > 0) {
      message("  Duplicate files detected: ", total_duplicates)
    }
    if(potential_rename_modify_count > 0) {
      message("  ⚠ Potential rename-and-modify pairs flagged: ", potential_rename_modify_count, " (requires review)")
    }
  }
  
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
        # Preserve full directory structure
        dest_dir = path(new_files_dir, directory),
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
        # Preserve full directory structure
        dest_dir = path(modified_files_dir, directory),
        dest_file = path(dest_dir, file_name),
        operation_type = "modified"
      )
    copy_operations <- c(copy_operations, list(modified_copy_ops))
  }
  
  # Process renamed files - copy to MODIFIED folder (they're modifications at the folder level)
  if(nrow(comparison_result$renamed_files) > 0) {
    message("Copying ", nrow(comparison_result$renamed_files), " renamed files to MODIFIED...")
    renamed_copy_ops <- comparison_result$renamed_files %>%
      mutate(
        source_file = full_path,
        # Preserve full directory structure
        dest_dir = path(modified_files_dir, directory),
        dest_file = path(dest_dir, file_name),
        operation_type = "renamed"
      )
    copy_operations <- c(copy_operations, list(renamed_copy_ops))
  }
  
  # Process reintroduced files - copy to NEW folder (they're new in this archive)
  if(nrow(comparison_result$reintroduced_files) > 0) {
    message("Copying ", nrow(comparison_result$reintroduced_files), " reintroduced files to NEW...")
    reintroduced_copy_ops <- comparison_result$reintroduced_files %>%
      mutate(
        source_file = full_path,
        # Preserve full directory structure
        dest_dir = path(new_files_dir, directory),
        dest_file = path(dest_dir, file_name),
        operation_type = "reintroduced"
      )
    copy_operations <- c(copy_operations, list(reintroduced_copy_ops))
  }
  
  # Create reference links for unchanged files
  if(nrow(comparison_result$unchanged_files) > 0) {
    message("Creating references for ", nrow(comparison_result$unchanged_files), " unchanged files...")
    unchanged_refs <- comparison_result$unchanged_files %>%
      mutate(
        reference_path = if(!is.null(previous_metadata)) {
          path(archive_root, previous_metadata$summary$snapshot_id, "archive", segment, deal, file_name)
        } else {
          NA_character_
        },
        dest_dir = path(unchanged_files_dir, segment, deal),
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
            # Use base R file.copy with copy.date=TRUE to preserve timestamps
            file.copy(.x, .y, overwrite = TRUE, copy.date = TRUE, copy.mode = TRUE)
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
        select(status, segment, deal, relative_path, file_name, size, modified_time, 
               any_of(c("current_archive_date", "first_seen_quarter", "last_archived_quarter",
                       "is_duplicate", "duplicate_of", 
                       "potential_rename_modify", "suggested_original_file", "match_confidence_score"))) %>%
        arrange(status, segment, deal, relative_path)
      
      write_csv(summary_df, path(current_staging_path, paste0(snapshot_id, "_file_summary.csv")))
      
      # Create segment/deal summary CSV (aggregated folder-level statistics)
      segment_deal_summary <- summary_df %>%
        group_by(segment, deal) %>%
        summarise(
          # The most recent quarter where files from this segment/deal were archived
          # This tells you which quarter's archive folder to look in for the files
          last_archived_quarter = max(last_archived_quarter, na.rm = TRUE),
          # Folder classification based on what action occurred this quarter
          folder_status = case_when(
            sum(status == "MODIFIED") > 0 | sum(status == "RENAMED") > 0 ~ "MODIFIED",
            sum(status == "NEW") > 0 | sum(status == "REINTRODUCED") > 0 ~ "NEW",
            TRUE ~ "UNCHANGED"
          ),
          # First seen quarter for this segment/deal is the earliest first_seen_quarter among all its files
          first_seen_quarter = min(first_seen_quarter, na.rm = TRUE),
          total_files = n(),
          new_files = sum(status == "NEW", na.rm = TRUE),
          modified_files = sum(status == "MODIFIED", na.rm = TRUE),
          renamed_files = sum(status == "RENAMED", na.rm = TRUE),
          reintroduced_files = sum(status == "REINTRODUCED", na.rm = TRUE),
          unchanged_files = sum(status == "UNCHANGED", na.rm = TRUE),
          # Get a sample folder path for reference
          sample_folder_path = first(dirname(relative_path)),
          .groups = "drop"
        ) %>%
        arrange(segment, deal)
      
      write_csv(segment_deal_summary, path(current_staging_path, paste0(snapshot_id, "_segment_deal_summary.csv")))
    }
    
    # Create separate CSV for removed files (including fuzzy match suggestions)
    if(nrow(comparison_result$removed_files) > 0) {
      removed_df <- comparison_result$removed_files %>%
        select(status, segment, deal, relative_path, file_name, size, modified_time,
               first_removed_quarter,
               potential_rename_modify, suggested_new_file, match_confidence_score) %>%
        arrange(segment, deal, relative_path)
      
      write_csv(removed_df, path(current_staging_path, paste0(snapshot_id, "_removed_files.csv")))
    }
    
    # Create fuzzy match suggestion CSV for human review
    # This shows potential renamed-and-modified file pairs sorted by confidence score
    # Each row represents one potential pair with both the removed and new file details
    
    if(nrow(comparison_result$removed_files) > 0 && nrow(comparison_result$new_files) > 0) {
      # Get removed files with their suggested new file matches
      removed_with_matches <- comparison_result$removed_files %>%
        filter(!is.na(match_confidence_score)) %>%
        select(
          removed_file = relative_path,
          removed_file_name = file_name,
          removed_size = size,
          removed_modified_time = modified_time,
          removed_segment = segment,
          removed_deal = deal,
          suggested_new_file,
          match_confidence_score,
          flagged_as_potential = potential_rename_modify
        )
      
      # Join with new files to get their details
      new_file_details <- comparison_result$new_files %>%
        select(
          new_file_path = relative_path,
          new_file_name = file_name,
          new_size = size,
          new_modified_time = modified_time,
          new_segment = segment,
          new_deal = deal
        )
      
      # Create final pairs CSV
      fuzzy_pairs <- removed_with_matches %>%
        left_join(new_file_details, by = c("suggested_new_file" = "new_file_path")) %>%
        select(
          match_confidence_score,
          flagged_as_potential,
          removed_file,
          removed_file_name,
          removed_size,
          removed_modified_time,
          removed_segment,
          removed_deal,
          suggested_new_file,
          new_file_name,
          new_size,
          new_modified_time,
          new_segment,
          new_deal
        ) %>%
        arrange(desc(match_confidence_score))
      
      if(nrow(fuzzy_pairs) > 0) {
        write_csv(fuzzy_pairs, 
                  path(current_staging_path, paste0(snapshot_id, "_fuzzy_match_pairs.csv")))
      }
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