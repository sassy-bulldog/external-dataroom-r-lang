# Example: Folder-Level Consolidation Workflow
#
# This script demonstrates the two-stage archiving approach:
# Stage 1: File-level analysis (existing incremental_archive.Rmd)
# Stage 2: Folder-level consolidation (this script)

source("folder_consolidation.R")

# ===== STAGE 1: File-Level Analysis (Already Complete) =====
# Run your normal incremental archive process:
# rmarkdown::render("incremental_archive.Rmd", params = list(
#   snapshot_id = "2025Q3",
#   source_path = "./source_files",
#   staging_path = "./temp_staging"
# ))
# 
# This creates:
# - temp_staging/2025Q3/2025Q3_metadata.json
# - temp_staging/2025Q3/2025Q3_file_summary.csv
# - temp_staging/2025Q3/NEW/, MODIFIED/, RENAMED/, UNCHANGED/, etc.

# ===== STAGE 2: Folder-Level Consolidation (New) =====

# 1. Review folder classifications before consolidation (optional)
cat("=== Step 1: Review Folder Classifications ===\n")
folder_review <- review_folder_classifications("./temp_staging/2025Q3")

# 2. Consolidate to folder-level final archive
cat("\n=== Step 2: Consolidate to Folder Archive ===\n")
results <- consolidate_to_folder_archive(
  staging_path = "./temp_staging/2025Q3",
  final_archive_path = "./final_archive/2025Q3",
  source_path = "./source_files"
)

# 3. Review results
cat("\n=== Step 3: Review Results ===\n")
cat("Folder Summary:\n")
print(results$folder_analysis)

cat("\nFiles Copied:\n")
if(!is.null(results$copy_results$new)) {
  cat("NEW folders: ", sum(results$copy_results$new$copy_success), " files\n")
}
if(!is.null(results$copy_results$modified)) {
  cat("MODIFIED folders: ", sum(results$copy_results$modified$copy_success), " files\n")
}
if(!is.null(results$copy_results$unchanged_count)) {
  cat("UNCHANGED folders: ", results$copy_results$unchanged_count, " files (referenced)\n")
}

cat("\nFinal archive created at:", results$final_archive_path, "\n")

# ===== Optional: Custom Processing =====

# If you want to customize which files go where, you can:
# 1. Load the file_summary.csv
# 2. Modify the folder_action column
# 3. Re-run consolidation with your customized data

# Example:
# file_summary <- read_csv("./temp_staging/2025Q3/2025Q3_file_summary.csv")
# 
# # Custom logic: Move specific segment to MODIFIED even if it's NEW
# file_summary <- file_summary %>%
#   mutate(folder_action = ifelse(segment == "SpecialSegment", "MODIFIED", folder_action))
# 
# # Then copy files based on your custom classification
