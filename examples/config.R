# Configuration Examples for Incremental Data Room Archive System

## Example 1: Simple Single Archive

```r
# Basic underwriting archive configuration
underwriting_config <- list(
  archive_name = "underwriting",
  snapshot_id = "2025Q2",
  source_path = "Z:/source/underwriting/2025Q2/",
  archive_root = "Z:/archive/underwriting/",
  staging_root = "Z:/staging/",
  classification_pattern = "^([^/]+)/([^/]+)/",  # Captures segment/deal
  exclude_patterns = c("Working Files", "\\.tmp$", "~\\$", "\\.log$")
)

# Execute single archive
result <- create_incremental_archive(underwriting_config)
```

## Example 2: Multiple Archives with Different Patterns

```r
# Configuration for multiple business areas
multi_config <- list(
  
  # Underwriting files (segment/deal structure)
  underwriting = list(
    archive_name = "underwriting",
    source_path = "Z:/source/underwriting/current/",
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("Working Files", "backup", "\\.tmp$")
  ),
  
  # Claims files (year/month/claim_type structure)  
  claims = list(
    archive_name = "claims",
    source_path = "Z:/source/claims/processed/",
    classification_pattern = "^([0-9]{4})/([0-9]{2})/([^/]+)/",
    exclude_patterns = c("temp", "draft", "\\.bak$")
  ),
  
  # Financial reports (department/period structure)
  financials = list(
    archive_name = "financials", 
    source_path = "Z:/source/finance/reports/",
    classification_pattern = "^([^/]+)/([0-9]{4}Q[1-4])/",
    exclude_patterns = c("working", "draft", "\\.xlsx~$")
  ),
  
  # Legal documents (case/document_type structure)
  legal = list(
    archive_name = "legal",
    source_path = "Z:/source/legal/documents/",
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("confidential", "attorney_work_product")
  )
)

# Execute all archives with global settings
global_snapshot_id <- "2025Q2"
archive_root <- "Z:/archive/"
staging_root <- "Z:/staging/"

results <- create_multiple_archives(multi_config, global_snapshot_id)
```

## Example 3: Large Scale Archive with Performance Optimization

```r
# High-performance configuration for large datasets
large_scale_config <- list(
  archive_name = "enterprise_data",
  snapshot_id = "2025Q2",
  source_path = "Z:/source/enterprise/",
  archive_root = "Z:/archive/enterprise/",
  staging_root = "Z:/staging/",
  classification_pattern = "^([^/]+)/([^/]+)/([^/]+)/",  # Three-level hierarchy
  exclude_patterns = c(
    "Working Files", "temp", "backup", "cache",
    "\\.tmp$", "\\.bak$", "\\.log$", "~\\$.*",
    "thumbs\\.db", "desktop\\.ini"
  ),
  
  # Performance settings
  use_parallel_processing = TRUE,
  max_workers = 6,
  batch_size = 100,
  quick_comparison_mode = FALSE,  # Use full hash comparison for accuracy
  enable_cache_management = TRUE,
  max_cache_age_days = 30
)

# Load performance functions
source("performance_functions.R")

# Execute with performance monitoring
start_time <- Sys.time()
result <- create_incremental_archive(large_scale_config)
end_time <- Sys.time()

cat("Processing completed in:", round(end_time - start_time, 2), "minutes\n")
cat("Files processed:", result$comparison_summary$total_files, "\n")
cat("Files copied:", result$files_copied, "\n")
```

## Example 4: Custom Classification Patterns

```r
# Different classification patterns for various business needs

# Pattern 1: Year/Month/Department/Project
pattern_1 <- "^([0-9]{4})/([0-9]{2})/([^/]+)/([^/]+)/"

# Pattern 2: Region/Product/Version  
pattern_2 <- "^([A-Z]{2,3})/([^/]+)/v([0-9]+\\.[0-9]+)/"

# Pattern 3: Client/Service/Date
pattern_3 <- "^([^/]+)/([^/]+)/([0-9]{4}-[0-9]{2}-[0-9]{2})/"

# Pattern 4: Simple two-level (Category/Subcategory)
pattern_4 <- "^([^/]+)/([^/]+)/"

# Example usage with custom pattern
custom_config <- list(
  archive_name = "client_services",
  source_path = "Z:/client_data/",
  classification_pattern = pattern_3,  # Client/Service/Date
  exclude_patterns = c("internal", "draft", "\\.tmp$")
)
```

## Example 5: Scheduled Automation with Error Handling

```r
# Scheduled archive function with comprehensive error handling
automated_archive <- function(config_file = "archive_config.json") {
  
  tryCatch({
    # Load configuration from file
    if(file.exists(config_file)) {
      configs <- jsonlite::read_json(config_file, simplifyVector = TRUE)
    } else {
      stop("Configuration file not found: ", config_file)
    }
    
    # Generate snapshot ID based on current date
    snapshot_id <- paste0(year(Sys.Date()), "Q", quarter(Sys.Date()))
    
    # Create log file
    log_file <- file.path("logs", paste0("archive_", snapshot_id, "_", 
                                        format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))
    dir.create("logs", showWarnings = FALSE)
    
    # Redirect output to log file
    sink(log_file, append = TRUE, type = "output")
    sink(log_file, append = TRUE, type = "message")
    
    message("=== Automated Archive Process Started ===")
    message("Timestamp: ", Sys.time())
    message("Snapshot ID: ", snapshot_id)
    
    # Execute archives
    results <- create_multiple_archives(configs, snapshot_id)
    
    # Check for errors
    failed_archives <- map_lgl(results$individual_results, ~ .x$files_failed > 0)
    if(any(failed_archives)) {
      warning("Some archives had failures. Check individual results.")
    }
    
    # Generate summary email/notification
    summary_text <- paste0(
      "Archive Process Summary for ", snapshot_id, "\n",
      "Archives processed: ", results$total_archives, "\n",
      "Total files: ", results$summary$total_files_processed, "\n",
      "Files copied: ", results$summary$total_files_copied, "\n",
      "Failed copies: ", sum(map_dbl(results$individual_results, ~ .x$files_failed)), "\n",
      "Log file: ", log_file
    )
    
    message("=== Archive Process Completed ===")
    message(summary_text)
    
    # Reset output
    sink(type = "message")
    sink(type = "output")
    
    # Send notification (implement based on your notification system)
    # send_notification(summary_text, log_file)
    
    return(results)
    
  }, error = function(e) {
    sink(type = "message")
    sink(type = "output")
    
    error_msg <- paste("Archive process failed:", e$message)
    message(error_msg)
    
    # Send error notification
    # send_error_notification(error_msg)
    
    stop(e)
  })
}

# Example configuration file (archive_config.json)
config_json <- list(
  underwriting = list(
    archive_name = "underwriting",
    source_path = "Z:/source/underwriting/current/",
    archive_root = "Z:/archive/underwriting/",
    staging_root = "Z:/staging/",
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("Working Files", "\\.tmp$")
  ),
  claims = list(
    archive_name = "claims",
    source_path = "Z:/source/claims/current/",
    archive_root = "Z:/archive/claims/", 
    staging_root = "Z:/staging/",
    classification_pattern = "^([^/]+)/([^/]+)/([^/]+)/",
    exclude_patterns = c("temp", "backup")
  )
)

# Save configuration to JSON file
jsonlite::write_json(config_json, "archive_config.json", pretty = TRUE, auto_unbox = TRUE)

# Run automated archive
# results <- automated_archive("archive_config.json")
```

## Example 6: Integration with External Systems

```r
# Integration with SharePoint, database logging, and notification systems
integrated_archive <- function(configs, snapshot_id) {
  
  # Pre-archive hooks
  log_to_database("archive_start", snapshot_id, Sys.time())
  
  # Execute archive
  results <- create_multiple_archives(configs, snapshot_id)
  
  # Post-archive processing
  for(archive_name in names(results$individual_results)) {
    result <- results$individual_results[[archive_name]]
    
    # Upload metadata to SharePoint
    # upload_to_sharepoint(result$metadata_file, archive_name, snapshot_id)
    
    # Log results to database
    log_to_database("archive_complete", snapshot_id, Sys.time(), 
                   archive_name, result$files_copied, result$files_failed)
    
    # Update external tracking systems
    # update_tracking_system(archive_name, snapshot_id, result$comparison_summary)
  }
  
  # Send consolidated notification
  send_teams_notification(create_summary_message(results))
  
  return(results)
}

# Example notification functions (implement based on your systems)
send_teams_notification <- function(message) {
  # Implement Teams webhook notification
  message("Teams notification: ", message)
}

log_to_database <- function(event_type, snapshot_id, timestamp, 
                           archive_name = NULL, files_copied = NULL, files_failed = NULL) {
  # Implement database logging
  message("Database log: ", event_type, " - ", snapshot_id)
}

create_summary_message <- function(results) {
  paste0(
    "📁 Archive Process Complete\n",
    "Snapshot: ", results$global_snapshot_id, "\n",
    "Archives: ", results$total_archives, "\n", 
    "Files Processed: ", format(results$summary$total_files_processed, big.mark = ","), "\n",
    "Files Copied: ", format(results$summary$total_files_copied, big.mark = ","), "\n",
    "New Files: ", format(results$summary$total_new_files, big.mark = ","), "\n",
    "Modified Files: ", format(results$summary$total_modified_files, big.mark = ",")
  )
}
```

## Example 7: Development and Testing Configuration

```r
# Development/testing configuration with small datasets
dev_config <- list(
  test_archive = list(
    archive_name = "test_data",
    source_path = "C:/temp/test_source/",
    archive_root = "C:/temp/test_archive/",
    staging_root = "C:/temp/test_staging/",
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("test_*", "\\.tmp$"),
    
    # Development settings
    max_files_per_category = 100,  # Limit for testing
    dry_run = FALSE,  # Set to TRUE to simulate without copying
    verbose_logging = TRUE
  )
)

# Test function with validation
test_archive_system <- function() {
  
  # Create test data structure
  setup_test_data("C:/temp/test_source/")
  
  # Run archive with test config
  result <- create_incremental_archive(dev_config$test_archive)
  
  # Validate results
  validation_results <- validate_archive_results(result)
  
  if(all(validation_results$checks)) {
    message("✅ All tests passed")
    return(TRUE)
  } else {
    message("❌ Some tests failed:")
    print(validation_results$failures)
    return(FALSE)
  }
}

# Validation function
validate_archive_results <- function(result) {
  checks <- list(
    metadata_exists = file.exists(result$metadata_file),
    staging_exists = dir.exists(result$staging_path),
    no_copy_failures = result$files_failed == 0,
    reasonable_file_count = result$files_copied >= 0 && result$files_copied <= 1000
  )
  
  list(
    checks = unlist(checks),
    failures = names(checks)[!unlist(checks)]
  )
}

setup_test_data <- function(base_path) {
  # Create test directory structure
  dir.create(file.path(base_path, "segment1", "deal1"), recursive = TRUE)
  dir.create(file.path(base_path, "segment1", "deal2"), recursive = TRUE)
  dir.create(file.path(base_path, "segment2", "deal1"), recursive = TRUE)
  
  # Create test files
  writeLines("test content 1", file.path(base_path, "segment1", "deal1", "test1.txt"))
  writeLines("test content 2", file.path(base_path, "segment1", "deal2", "test2.txt"))
  writeLines("test content 3", file.path(base_path, "segment2", "deal1", "test3.txt"))
}
```