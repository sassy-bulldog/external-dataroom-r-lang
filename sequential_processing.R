#' Sequential Quarter Processing
#' 
#' This script processes quarters sequentially from their original source folders
#' to build a proper incremental archive with accurate comparisons.

# Load required libraries and functions
source("dataroom_functions.R")

#' Process all quarters sequentially to build incremental archive
#'
#' @param base_source_path Base path where quarterly source folders are located
#' @param base_archive_path Base path where the new archive should be created
#' @param quarters Vector of quarter IDs to process (e.g., c("2024Q4", "2025Q1", "2025Q2", "2025Q3"))
#' @param classification_pattern Regex pattern to extract classification info
#' @param exclude_patterns Vector of regex patterns for paths to exclude
#' @return List of results for each quarter
process_quarters_sequentially <- function(
  base_source_path = "/mnt/z/Shared/Jaffa Main/Insurance/Reserving and Valuations/Data Room Prep/20250930/Underwriting",
  base_archive_path = "./temp_staging",  # Use local directory 
  quarters = c("2024Q4", "2025Q1", "2025Q2", "2025Q3"),
  classification_pattern = "^([^/]+)/([^/]+)/",
  exclude_patterns = c("Working Files", "\\.tmp$", "~\\$", "\\.log$")
) {
  
  message("=== Sequential Quarter Processing ===")
  message("Source Base: ", base_source_path)
  message("Archive Base: ", base_archive_path)
  message("Quarters to process: ", paste(quarters, collapse = ", "))
  
  # Create base archive directory if it doesn't exist
  dir_create(base_archive_path)
  
  results <- list()
  
  for(quarter in quarters) {
    message("\n", paste(rep("=", 50), collapse = ""))
    message("Processing Quarter: ", quarter)
    message(paste(rep("=", 50), collapse = ""))
    
    # Determine source path for this quarter - all start with TEMP_
    source_path <- path(base_source_path, paste0("TEMP_", quarter))
    
    # Check if source exists
    if(!dir_exists(source_path)) {
      warning("Source path does not exist for ", quarter, ": ", source_path)
      next
    }
    
    message("Source Path: ", source_path)
    message("Archive Path: ", base_archive_path)
    
    # Create configuration for this quarter
    # Use local temp_staging for both archive and staging to avoid mount issues
    config <- list(
      archive_name = "",  # No subdirectory appending
      snapshot_id = quarter,
      source_path = source_path,
      archive_root = base_archive_path,
      staging_root = base_archive_path,  # Use same local directory for staging
      classification_pattern = classification_pattern,
      exclude_patterns = exclude_patterns
    )
    
    # Process this quarter
    tryCatch({
      result <- create_incremental_archive(config)
      results[[quarter]] <- result
      
      message("✅ ", quarter, " completed successfully")
      message("   Files copied: ", result$files_copied)
      message("   New files: ", result$comparison_summary$new_count)
      message("   Modified files: ", result$comparison_summary$modified_count)
      message("   Unchanged files: ", result$comparison_summary$unchanged_count)
      if(!is.null(result$comparison_summary$renamed_count)) {
        message("   Renamed files: ", result$comparison_summary$renamed_count)
      }
      if(!is.null(result$comparison_summary$reintroduced_count)) {
        message("   Reintroduced files: ", result$comparison_summary$reintroduced_count)
      }
      
    }, error = function(e) {
      warning("Failed to process ", quarter, ": ", e$message)
      results[[quarter]] <- list(error = e$message)
    })
  }
  
  message("\n", paste(rep("=", 50), collapse = ""))
  message("PROCESSING COMPLETE")
  message(paste(rep("=", 50), collapse = ""))
  
  # Print summary
  successful <- names(results)[!sapply(results, function(x) "error" %in% names(x))]
  failed <- names(results)[sapply(results, function(x) "error" %in% names(x))]
  
  message("✅ Successfully processed: ", paste(successful, collapse = ", "))
  if(length(failed) > 0) {
    message("❌ Failed: ", paste(failed, collapse = ", "))
  }
  
  return(results)
}

#' Verify available quarter source directories
verify_quarter_sources <- function(
  base_source_path = "/mnt/z/Shared/Jaffa Main/Insurance/Reserving and Valuations/Data Room Prep/20250930/Underwriting"
) {
  message("=== Verifying Quarter Sources ===")
  message("Base path: ", base_source_path)
  
  if(!dir_exists(base_source_path)) {
    stop("Base source path does not exist: ", base_source_path)
  }
  
  # Check for available directories
  all_dirs <- dir_ls(base_source_path, type = "directory")
  dir_names <- path_file(all_dirs)
  
  message("Available directories:")
  walk(dir_names, ~ message("  - ", .x))
  
  # Check for TEMP_ prefixed quarterly patterns
  temp_pattern <- "^TEMP_(\\d{4}Q[1-4])$"
  temp_dirs <- dir_names[grepl(temp_pattern, dir_names)]
  
  message("\nTEMP_ quarterly directories found:")
  walk(temp_dirs, ~ message("  - ", .x))
  
  # Extract quarter IDs from TEMP_ directories
  suggested_quarters <- character()
  for(temp_dir in temp_dirs) {
    quarter_match <- str_match(temp_dir, temp_pattern)
    if(!is.na(quarter_match[2])) {
      suggested_quarters <- c(suggested_quarters, quarter_match[2])
    }
  }
  
  # Sort chronologically
  suggested_quarters <- sort(suggested_quarters)
  
  message("\nSuggested processing order:")
  walk(suggested_quarters, ~ message("  ", which(suggested_quarters == .x), ". ", .x))
  
  return(list(
    all_dirs = dir_names,
    temp_dirs = temp_dirs,
    suggested_order = suggested_quarters
  ))
}

#' Main execution function
run_sequential_processing <- function() {
  # First verify what's available
  verification <- verify_quarter_sources()
  
  if(length(verification$suggested_order) == 0) {
    stop("No quarterly directories found to process")
  }
  
  # Process all available quarters
  results <- process_quarters_sequentially(
    quarters = verification$suggested_order
  )
  
  return(results)
}

# Utility function to clean up old archive if needed
clean_archive_directory <- function(
  archive_path = "/mnt/z/Shared/Jaffa Main/Insurance/Reserving and Valuations/Data Room Prep/20250930/Underwriting/Content"
) {
  message("⚠️  WARNING: This will delete the existing archive directory!")
  message("Archive path: ", archive_path)
  
  if(dir_exists(archive_path)) {
    message("Directory exists. Contents:")
    existing_contents <- dir_ls(archive_path)
    walk(existing_contents, ~ message("  - ", .x))
    
    # Uncomment the next line to actually delete (BE CAREFUL!)
    # dir_delete(archive_path)
    # message("✅ Archive directory cleaned")
  } else {
    message("Archive directory does not exist - will be created fresh")
  }
}

# Example usage:
# First verify what quarters are available:
# verify_quarter_sources()

# Clean the target archive directory if needed (CAREFUL!):
# clean_archive_directory()

# Then run the sequential processing:
# results <- run_sequential_processing()

message("Script loaded. Available functions:")
message("  - verify_quarter_sources() : Check available source directories")
message("  - clean_archive_directory() : Clean target archive (BE CAREFUL!)")
message("  - run_sequential_processing() : Process all quarters sequentially")
message("  - process_quarters_sequentially() : Process specific quarters")