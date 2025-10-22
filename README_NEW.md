# Incremental Data Room Archive System

This repository contains a generalized, high-performance incremental archive system for data rooms. Originally developed for underwriting files, it has been expanded to handle any source folder structure with intelligent change detection, metadata caching, and multi-source processing capabilities.

## Files

### Core Files
- **`dataroom_functions.R`** - Main generalized archive functions with JSON metadata caching
- **`performance_functions.R`** - Performance optimizations for large-scale operations
- **`incremental_archive.Rmd`** - Flexible RMarkdown orchestrator for multiple archives
- **`config_examples.R`** - Comprehensive configuration examples and patterns

### Legacy Files (Preserved for Reference)
- **`underwriting_functions.R`** - Original underwriting-specific functions
- **`underwriting_archive.Rmd`** - Original underwriting-specific RMarkdown
- **`underwriting.R`** - Original monolithic script
- **`example_usage.R`** - Basic usage examples

## Key Features

1. **Universal Application**: Works with any folder structure and classification system
2. **Intelligent Caching**: JSON metadata files with MD5 hashes for fast comparisons
3. **Multi-Source Processing**: Handle multiple archive types in a single operation
4. **Performance Optimized**: Parallel processing, batch operations, and smart comparison strategies
5. **Change Detection**: Identifies new, modified, renamed, and unchanged files
6. **Flexible Classification**: Configurable regex patterns for different folder structures

## Usage Methods

### Method 1: Multi-Source RMarkdown (Recommended)
```r
# Configure multiple archives in YAML parameters
rmarkdown::render("incremental_archive.Rmd")
```

### Method 2: Single Archive with Custom Config
```r
source("dataroom_functions.R")

config <- list(
  archive_name = "underwriting",
  snapshot_id = "2025Q3",
  source_path = "Z:/source/underwriting/2025Q3/",
  archive_root = "Z:/archive/underwriting/",
  staging_root = "Z:/staging/",
  classification_pattern = "^([^/]+)/([^/]+)/",  # segment/deal
  exclude_patterns = c("Working Files", "\\.tmp$", "~\\$")
)

result <- create_incremental_archive(config)
```

### Method 3: Multiple Archives Programmatically
```r
source("dataroom_functions.R")

multi_config <- list(
  underwriting = list(
    archive_name = "underwriting",
    source_path = "Z:/source/underwriting/current/",
    classification_pattern = "^([^/]+)/([^/]+)/",
    exclude_patterns = c("Working Files", "\\.tmp$")
  ),
  claims = list(
    archive_name = "claims", 
    source_path = "Z:/source/claims/current/",
    classification_pattern = "^([^/]+)/([^/]+)/([^/]+)/",
    exclude_patterns = c("temp", "backup")
  )
)

results <- create_multiple_archives(multi_config, "2025Q3")
```

### Method 4: High-Performance Large Scale
```r
source("dataroom_functions.R")
source("performance_functions.R")

# Load optimized configurations from config_examples.R
# See Example 3 for large-scale configuration
```

## Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `archive_name` | Unique identifier for this archive type | "underwriting", "claims" |
| `snapshot_id` | Period/version identifier (must sort correctly) | "2025Q2", "monthly_2025_10" |
| `source_path` | Location of current source files | "Z:/source/underwriting/2025Q2/" |
| `archive_root` | Root directory for this archive type | "Z:/archive/underwriting/" |
| `staging_root` | Temporary processing location | "Z:/staging/" |
| `classification_pattern` | Regex to extract folder structure | "^([^/]+)/([^/]+)/" |
| `exclude_patterns` | Array of exclusion patterns | `["Working Files", "\\.tmp$"]` |

### Classification Pattern Examples

- **Two-level**: `"^([^/]+)/([^/]+)/"` → segment/deal
- **Three-level**: `"^([^/]+)/([^/]+)/([^/]+)/"` → year/month/type  
- **Date-based**: `"^([0-9]{4})/([0-9]{2})/([^/]+)/"` → year/month/category
- **Custom**: `"^([A-Z]{2,3})/([^/]+)/v([0-9]+)/"` → region/product/version

## System Requirements

### Required R Packages
- **Core**: `fs`, `tidyverse`, `stringr`, `lubridate`, `jsonlite`, `digest`
- **Performance** (optional): `future`, `furrr` for parallel processing
- **Visualization** (optional): `DT`, `plotly`, `kableExtra` for enhanced reports

### System Dependencies
- **Windows**: PowerShell 5.1+ (for robocopy and hash calculations)
- **Linux/Mac**: Standard command-line tools (`md5sum`, `sha1sum`, etc.)
- **Cross-platform**: R's built-in file operations (fallback)

## JSON Metadata System

Each snapshot creates a JSON metadata file containing:
- **File inventory**: Complete list with paths, sizes, timestamps, MD5 hashes
- **Classification data**: Extracted categories based on folder structure  
- **Summary statistics**: File counts, sizes, types by category
- **Performance metadata**: Processing time, comparison statistics

Benefits:
- **Fast comparisons**: No need to rescan entire filesystems
- **Change tracking**: Detailed history of what changed between snapshots
- **Debugging**: Complete audit trail of all processing decisions
- **Integration**: JSON format easily consumed by external systems

## Output Structure

```
{staging_root}/{snapshot_id}/
├── NEW/                           # New files by category
│   ├── {category1}/
│   │   └── {category2}/
├── MODIFIED/                      # Modified files by category  
│   ├── {category1}/
│   │   └── {category2}/
├── UNCHANGED/                     # Reference links to previous snapshots
├── {snapshot_id}_metadata.json        # Complete file metadata
├── {snapshot_id}_archive_report.json  # Processing results  
├── {snapshot_id}_file_summary.csv     # Human-readable summary
└── unchanged_file_references.csv      # Previous snapshot references
```

## Migration from Original System

### From Underwriting Script
1. Use `underwriting_functions.R` for drop-in compatibility
   - OR migrate to new system for better performance and features
2. Update paths in configuration
3. Run `incremental_archive.Rmd` instead of knitting original script

### To New Generalized System
1. Define `classification_pattern` for your folder structure
2. Set `exclude_patterns` for files to ignore
3. Configure multiple archives in single YAML file
4. Use JSON metadata for faster subsequent runs

## Performance and Scalability

- **Parallel processing**: Configure `max_workers` for CPU-bound operations
- **Batch operations**: Optimized file copying in configurable batch sizes
- **Smart comparisons**: Skip expensive hash calculations when possible
- **Cache management**: Automatic cleanup of old metadata files
- **Memory efficiency**: Process large datasets in chunks

See `config_examples.R` for performance tuning examples.