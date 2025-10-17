#' Retroactive Metadata Generation
#' 
#' This script generates metadata JSON files for existing archive snapshots
#' that were created without the incremental archive system.

# Load required libraries and functions
source("dataroom_functions.R")

#' Generate metadata for an existing snapshot directory
#'
#' @param snapshot_path Path to existing snapshot directory (e.g., "archive/2025Q2")
#' @param snapshot_id Snapshot identifier (e.g., "2025Q2")
#' @param classification_pattern Regex pattern to extract classification info
#' @param exclude_patterns Vector of regex patterns for paths to exclude
#' @return Path to created metadata file
generate_retroactive_metadata <- function(
  snapshot_path,
  snapshot_id,
  classification_pattern = "^([^/]+)/([^/]+)/",
  exclude_patterns = c("Working Files", "\\.tmp$", "~\\$", "\\.log$")
) {
  
  message("=== Generating Retroactive Metadata ===")
  message("Snapshot Path: ", snapshot_path)
  message("Snapshot ID: ", snapshot_id)
  
  if(!dir_exists(snapshot_path)) {
    stop("Snapshot directory does not exist: ", snapshot_path)
  }
  
  # Create metadata file path
  metadata_file <- path(snapshot_path, paste0(snapshot_id, "_metadata.json"))
  
  if(file_exists(metadata_file)) {
    warning("Metadata file already exists: ", metadata_file)
    return(metadata_file)
  }
  
  # Generate metadata by scanning the snapshot directory
  metadata <- create_snapshot_metadata(
    source_path = snapshot_path,
    snapshot_id = snapshot_id,
    metadata_file = metadata_file,
    classification_pattern = classification_pattern,
    exclude_patterns = exclude_patterns
  )
  
  # Save the metadata
  write_json(metadata, metadata_file, pretty = TRUE, auto_unbox = TRUE)
  
  message("✅ Metadata file created: ", metadata_file)
  message("📊 Files cataloged: ", length(metadata$files))
  
  return(metadata_file)
}

#' Generate metadata for all snapshots in an archive directory
#'
#' @param archive_root_path Path to archive root containing snapshot subdirectories
#' @param classification_pattern Regex pattern to extract classification info
#' @param exclude_patterns Vector of regex patterns for paths to exclude
#' @return Vector of created metadata file paths
generate_all_retroactive_metadata <- function(
  archive_root_path,
  classification_pattern = "^([^/]+)/([^/]+)/",
  exclude_patterns = c("Working Files", "\\.tmp$", "~\\$", "\\.log$")
) {
  
  message("=== Scanning Archive Directory ===")
  message("Archive Root: ", archive_root_path)
  
  if(!dir_exists(archive_root_path)) {
    stop("Archive directory does not exist: ", archive_root_path)
  }
  
  # Find all subdirectories that look like snapshot IDs
  snapshot_dirs <- dir_ls(archive_root_path, type = "directory")
  snapshot_ids <- path_file(snapshot_dirs)
  
  # Filter for directories that look like quarterly snapshots (optional)
  # This regex matches patterns like: 2024Q4, 2025Q1, 2025Q2, etc.
  quarterly_pattern <- "^\\d{4}Q[1-4]$"
  quarterly_snapshots <- snapshot_dirs[grepl(quarterly_pattern, snapshot_ids)]
  
  if(length(quarterly_snapshots) == 0) {
    message("No quarterly snapshot directories found matching pattern: ", quarterly_pattern)
    message("Available directories: ", paste(snapshot_ids, collapse = ", "))
    
    # If no quarterly patterns found, process all directories
    all_snapshots <- snapshot_dirs
    message("Processing all ", length(all_snapshots), " directories...")
  } else {
    all_snapshots <- quarterly_snapshots
    message("Found ", length(all_snapshots), " quarterly snapshots to process...")
  }
  
  # Generate metadata for each snapshot
  metadata_files <- map_chr(all_snapshots, function(snapshot_path) {
    snapshot_id <- path_file(snapshot_path)
    
    tryCatch({
      generate_retroactive_metadata(
        snapshot_path = snapshot_path,
        snapshot_id = snapshot_id,
        classification_pattern = classification_pattern,
        exclude_patterns = exclude_patterns
      )
    }, error = function(e) {
      warning("Failed to generate metadata for ", snapshot_id, ": ", e$message)
      return(NA_character_)
    })
  })
  
  # Remove any failed attempts
  successful_files <- metadata_files[!is.na(metadata_files)]
  
  message("\n=== Summary ===")
  message("✅ Successfully generated: ", length(successful_files), " metadata files")
  message("❌ Failed: ", sum(is.na(metadata_files)), " snapshots")
  
  if(length(successful_files) > 0) {
    message("\nGenerated metadata files:")
    walk(successful_files, ~ message("  - ", .x))
  }
  
  return(successful_files)
}

# Example usage functions
#' Generate metadata for your specific archive structure
generate_underwriting_metadata <- function() {
  archive_path <- "/mnt/z/Shared/Jaffa Main/Insurance/Reserving and Valuations/Data Room Prep/20250630/Huggins Dataroom/Underwriting/Content/underwriting"
  
  generate_all_retroactive_metadata(
    archive_root_path = archive_path,
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("Working Files", "\\.tmp$", "~\\$", "\\.log$")
  )
}

#' Test function for a single snapshot
test_single_snapshot <- function() {
  snapshot_path <- "/mnt/z/Shared/Jaffa Main/Insurance/Reserving and Valuations/Data Room Prep/20250630/Huggins Dataroom/Underwriting/Content/underwriting/2025Q2"
  
  generate_retroactive_metadata(
    snapshot_path = snapshot_path,
    snapshot_id = "2025Q2",
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("Working Files", "\\.tmp$", "~\\$", "\\.log$")
  )
}

# Uncomment one of these to run:
# test_single_snapshot()  # Test with just 2025Q2
# generate_underwriting_metadata()  # Process all snapshots