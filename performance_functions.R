#' Performance Optimization Functions for Data Room Archives
#' 
#' Additional functions to optimize performance for large-scale archive operations

#' Parallel File Processing with Progress
#'
#' Process files in parallel chunks with progress reporting
#'
#' @param file_list Vector of file paths to process
#' @param process_func Function to apply to each file
#' @param chunk_size Number of files per chunk
#' @param max_workers Maximum number of parallel workers
#' @return Results from processing all files
#' @export
process_files_parallel <- function(file_list, process_func, chunk_size = 100, max_workers = 4) {
  
  if(!requireNamespace("future", quietly = TRUE) || !requireNamespace("furrr", quietly = TRUE)) {
    message("Parallel processing requires 'future' and 'furrr' packages. Processing sequentially.")
    return(map(file_list, process_func))
  }
  
  library(future)
  library(furrr)
  
  # Setup parallel processing
  plan(multisession, workers = min(max_workers, parallel::detectCores() - 1))
  
  # Split into chunks
  file_chunks <- split(file_list, ceiling(seq_along(file_list) / chunk_size))
  
  message("Processing ", length(file_list), " files in ", length(file_chunks), " chunks with ", 
          nbrOfWorkers(), " workers")
  
  # Process chunks in parallel
  results <- future_map(file_chunks, ~ {
    map(.x, process_func)
  }, .progress = TRUE)
  
  # Reset to sequential processing
  plan(sequential)
  
  # Flatten results
  unlist(results, recursive = FALSE)
}

#' Fast File Hash Calculation
#'
#' Calculate file hashes more efficiently using system tools when available
#'
#' @param file_path Path to file
#' @param algorithm Hash algorithm (md5, sha1, sha256)
#' @return File hash string
#' @export
fast_file_hash <- function(file_path, algorithm = "md5") {
  
  # Try system-level hash tools first (much faster)
  if(Sys.info()["sysname"] == "Windows") {
    if(algorithm == "md5") {
      tryCatch({
        result <- system2("certutil", c("-hashfile", shQuote(file_path), "MD5"), 
                         stdout = TRUE, stderr = FALSE)
        if(length(result) >= 2) {
          return(str_trim(result[2]))
        }
      }, error = function(e) NULL)
    }
  } else {
    # Unix-like systems
    cmd <- switch(algorithm,
                  "md5" = "md5sum",
                  "sha1" = "sha1sum", 
                  "sha256" = "sha256sum",
                  NULL)
    
    if(!is.null(cmd)) {
      tryCatch({
        result <- system2(cmd, shQuote(file_path), stdout = TRUE, stderr = FALSE)
        if(length(result) > 0) {
          return(str_split(result[1], "\\s+")[[1]][1])
        }
      }, error = function(e) NULL)
    }
  }
  
  # Fallback to R digest
  digest::digest(file = file_path, algo = algorithm)
}

#' Smart Metadata Cache Management
#'
#' Manage metadata cache files with automatic cleanup and validation
#'
#' @param cache_root Root directory for cache files
#' @param max_age_days Maximum age of cache files in days
#' @param max_size_gb Maximum total cache size in GB
#' @return List of cache management results
#' @export
manage_metadata_cache <- function(cache_root, max_age_days = 90, max_size_gb = 5) {
  
  if(!dir_exists(cache_root)) {
    return(list(message = "Cache directory does not exist"))
  }
  
  # Find all metadata files
  metadata_files <- dir_ls(cache_root, recurse = TRUE, glob = "*_metadata.json")
  
  if(length(metadata_files) == 0) {
    return(list(message = "No metadata files found"))
  }
  
  # Get file information
  file_info <- map_dfr(metadata_files, ~ {
    info <- file_info(.x)
    tibble(
      file_path = .x,
      size = info$size,
      modified = info$modification_time,
      age_days = as.numeric(Sys.time() - info$modification_time, units = "days")
    )
  })
  
  # Identify files to clean up
  old_files <- file_info %>%
    filter(age_days > max_age_days) %>%
    pull(file_path)
  
  # Check total size
  total_size_gb <- sum(file_info$size) / (1024^3)
  size_excess <- total_size_gb > max_size_gb
  
  files_to_remove <- c()
  cleanup_reason <- c()
  
  if(length(old_files) > 0) {
    files_to_remove <- c(files_to_remove, old_files)
    cleanup_reason <- c(cleanup_reason, rep("age", length(old_files)))
  }
  
  if(size_excess) {
    # Remove largest/oldest files first
    size_candidates <- file_info %>%
      filter(!file_path %in% old_files) %>%
      arrange(desc(size), desc(age_days)) %>%
      mutate(cumulative_size = cumsum(size) / (1024^3)) %>%
      filter(cumulative_size <= (total_size_gb - max_size_gb)) %>%
      pull(file_path)
    
    files_to_remove <- c(files_to_remove, size_candidates)
    cleanup_reason <- c(cleanup_reason, rep("size", length(size_candidates)))
  }
  
  # Perform cleanup
  cleanup_results <- tibble(
    file_path = files_to_remove,
    reason = cleanup_reason,
    removed = map_lgl(file_path, ~ {
      tryCatch({
        file_delete(.x)
        TRUE
      }, error = function(e) {
        warning("Failed to delete: ", .x, " - ", e$message)
        FALSE
      })
    })
  )
  
  list(
    total_files = nrow(file_info),
    total_size_gb = round(total_size_gb, 2),
    files_removed = sum(cleanup_results$removed),
    space_freed_gb = round(sum(file_info$size[files_to_remove][cleanup_results$removed]) / (1024^3), 2),
    cleanup_details = cleanup_results
  )
}

#' Optimized File Comparison
#'
#' Fast file comparison using size and timestamp first, then hash only if needed
#'
#' @param current_files Current file metadata
#' @param previous_files Previous file metadata  
#' @param quick_mode If TRUE, skip hash comparison for performance
#' @return Comparison results
#' @export
optimized_file_comparison <- function(current_files, previous_files, quick_mode = FALSE) {
  
  if(is.null(previous_files) || nrow(previous_files) == 0) {
    return(list(
      new_files = current_files,
      modified_files = tibble(),
      unchanged_files = tibble(),
      performance_stats = list(hash_comparisons = 0, quick_mode = quick_mode)
    ))
  }
  
  # Stage 1: Quick comparison using size and timestamp
  current_quick <- current_files %>%
    mutate(quick_key = paste(relative_path, size, modified_time, sep = "|"))
  
  previous_quick <- previous_files %>%
    mutate(quick_key = paste(relative_path, size, modified_time, sep = "|"))
  
  # Files unchanged by quick comparison
  unchanged_files <- current_quick %>%
    inner_join(previous_quick, by = "quick_key", suffix = c("", "_prev")) %>%
    select(all_of(names(current_files)))
  
  # Files potentially modified (exist in both but different quick_key)
  potentially_modified <- current_quick %>%
    inner_join(previous_quick %>% select(relative_path, quick_key_prev = quick_key, md5_hash_prev = md5_hash), 
               by = "relative_path") %>%
    filter(quick_key != quick_key_prev)
  
  # New files (don't exist in previous)
  new_files <- current_quick %>%
    anti_join(previous_quick, by = "relative_path") %>%
    select(all_of(names(current_files)))
  
  hash_comparisons <- 0
  
  if(quick_mode || nrow(potentially_modified) == 0) {
    # In quick mode, treat all potentially modified as actually modified
    modified_files <- potentially_modified %>%
      select(all_of(names(current_files)))
  } else {
    # Stage 2: Hash comparison for potentially modified files
    hash_comparisons <- nrow(potentially_modified)
    
    modified_files <- potentially_modified %>%
      filter(md5_hash != md5_hash_prev) %>%
      select(all_of(names(current_files)))
    
    # Files that have different timestamps but same content
    actually_unchanged <- potentially_modified %>%
      filter(md5_hash == md5_hash_prev) %>%
      select(all_of(names(current_files)))
    
    unchanged_files <- bind_rows(unchanged_files, actually_unchanged)
  }
  
  performance_stats <- list(
    hash_comparisons = hash_comparisons,
    quick_mode = quick_mode,
    quick_unchanged = nrow(unchanged_files),
    hash_verified_unchanged = if(!quick_mode) nrow(potentially_modified) - nrow(modified_files) else 0
  )
  
  list(
    new_files = new_files,
    modified_files = modified_files,
    unchanged_files = unchanged_files,
    performance_stats = performance_stats
  )
}

#' Batch File Operations
#'
#' Perform file copy operations in optimized batches
#'
#' @param copy_operations Tibble of copy operations with source_file and dest_file columns
#' @param batch_size Number of operations per batch
#' @param use_robocopy Use robocopy on Windows for better performance
#' @return Results of copy operations
#' @export
batch_file_operations <- function(copy_operations, batch_size = 50, use_robocopy = TRUE) {
  
  if(nrow(copy_operations) == 0) {
    return(tibble())
  }
  
  # Create destination directories first
  unique_dirs <- unique(path_dir(copy_operations$dest_file))
  walk(unique_dirs, ~ dir_create(.x))
  
  # Split into batches
  copy_operations$batch_id <- ceiling(seq_len(nrow(copy_operations)) / batch_size)
  batches <- split(copy_operations, copy_operations$batch_id)
  
  message("Processing ", nrow(copy_operations), " copy operations in ", length(batches), " batches")
  
  # Process each batch
  batch_results <- map_dfr(batches, function(batch) {
    
    if(use_robocopy && Sys.info()["sysname"] == "Windows" && nrow(batch) > 10) {
      # Use robocopy for large batches on Windows
      tryCopy_robocopy(batch)
    } else {
      # Standard R file copy
      batch %>%
        mutate(
          copy_success = map2_lgl(source_file, dest_file, ~ {
            tryCatch({
              file_copy(.x, .y, overwrite = TRUE)
              TRUE
            }, error = function(e) {
              warning("Copy failed: ", .x, " -> ", .y, " Error: ", e$message)
              FALSE
            })
          })
        )
    }
  })
  
  success_count <- sum(batch_results$copy_success)
  message("Copy operations completed: ", success_count, "/", nrow(copy_operations), " successful")
  
  batch_results
}

#' Robocopy Batch Operation (Windows only)
#'
#' Use robocopy for efficient batch file copying on Windows
#'
#' @param batch Batch of copy operations
#' @return Results with copy_success column
tryCopy_robocopy <- function(batch) {
  
  # Group by source directory for efficient robocopy usage
  batch_grouped <- batch %>%
    mutate(
      source_dir = path_dir(source_file),
      source_name = path_file(source_file),
      dest_dir = path_dir(dest_file)
    ) %>%
    group_by(source_dir, dest_dir) %>%
    summarise(
      files = list(tibble(
        source_file = source_file,
        dest_file = dest_file,
        source_name = source_name
      )),
      .groups = "drop"
    )
  
  # Execute robocopy for each group
  results <- map2_dfr(batch_grouped$source_dir, batch_grouped$dest_dir, function(src_dir, dest_dir) {
    
    files_in_group <- batch_grouped$files[batch_grouped$source_dir == src_dir & 
                                         batch_grouped$dest_dir == dest_dir][[1]]
    
    tryCatch({
      # Create a temporary file list for robocopy
      file_list <- tempfile(fileext = ".txt")
      writeLines(files_in_group$source_name, file_list)
      
      # Execute robocopy
      result <- system2("robocopy", 
                       c(shQuote(src_dir), shQuote(dest_dir), paste0("/L:", shQuote(file_list))),
                       stdout = TRUE, stderr = TRUE)
      
      # Robocopy exit codes: 0-7 are success, 8+ are errors
      success <- attr(result, "status") %||% 0 <= 7
      
      files_in_group %>%
        mutate(copy_success = success)
      
    }, error = function(e) {
      warning("Robocopy failed for batch: ", e$message)
      files_in_group %>%
        mutate(copy_success = FALSE)
    })
  })
  
  results
}