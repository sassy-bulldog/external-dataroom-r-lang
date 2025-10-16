# Examples Directory

This directory contains configuration examples and documentation for the **Data Room Archive System**.

## 📁 Files Overview

| File | Purpose | Usage |
|------|---------|-------|
| `config.R` | **Executable configuration examples** | `source("examples/config.R")` |
| `config_documentation.Rmd` | **Comprehensive guide with rich formatting** | Knit to HTML/PDF for reading |
| `README.md` | **Quick reference** (this file) | Overview and quick start |

## 🚀 Quick Start

### 1. Basic Usage
```r
# Load the main functions
source("dataroom_functions.R")

# Load configuration examples
source("examples/config.R")

# Use a predefined configuration
result <- create_incremental_archive(underwriting_config)
```

### 2. Multi-Archive Setup
```r
# Execute multiple archives at once
results <- create_multiple_archives(multi_config, "2025Q4")
```

### 3. Performance Mode
```r
# Load performance functions for large datasets
source("performance_functions.R")

# Use high-performance configuration
result <- create_incremental_archive(large_scale_config)
```

## 📖 Configuration Patterns

### Essential Configuration Structure
```r
config <- list(
  archive_name = "your_archive_name",
  source_path = "/path/to/source/",           # WSL: /mnt/z/path/
  archive_root = "/path/to/archive/",         # Windows: Z:/path/
  staging_root = "/path/to/staging/",
  classification_pattern = "^([^/]+)/([^/]+)/",  # Regex with capture groups
  exclude_patterns = c("Working Files", "\\.tmp$")
)
```

### Common Classification Patterns

| Pattern | Use Case | Example |
|---------|----------|---------|
| `"^([^/]+)/([^/]+)/"` | Segment/Deal | `SegmentA/Deal123/` |
| `"^([0-9]{4})/([0-9]{2})/([^/]+)/"` | Year/Month/Type | `2025/03/Claims/` |
| `"^([^/]+)/([0-9]{4}Q[1-4])/"` | Dept/Quarter | `Finance/2025Q1/` |
| `"^([^/]+)/([^/]+)/([0-9]{4}-[0-9]{2}-[0-9]{2})/"` | Client/Service/Date | `ClientA/Service/2025-03-15/` |

### Exclude Pattern Examples

| Pattern | Excludes |
|---------|----------|
| `"\\.tmp$"` | Files ending in .tmp |
| `"Working Files"` | "Working Files" folders |
| `"~\\$.*"` | Excel temporary files |
| `"backup"` | "backup" folders |
| `c("temp", "draft", "\\.bak$")` | Multiple patterns |

## 🏗️ Project Structure Integration

```
external-dataroom-r-lang/
├── dataroom_functions.R          # Main functions (source first)
├── performance_functions.R        # Optimization functions  
├── incremental_archive.Rmd       # Multi-source orchestrator
├── examples/
│   ├── config.R                  # ← Executable configurations
│   ├── config_documentation.Rmd  # ← Rich documentation  
│   └── README.md                 # ← This quick reference
└── ...
```

## 💡 Usage Scenarios

### Scenario 1: Single Archive
Perfect for simple setups with one source folder.

```r
source("dataroom_functions.R")
source("examples/config.R")
result <- create_incremental_archive(underwriting_config)
```

### Scenario 2: Multiple Business Areas  
Process several archives with different configurations.

```r
results <- create_multiple_archives(multi_config, "2025Q4")
print(results$summary)
```

### Scenario 3: Automated/Scheduled
Run archives automatically with JSON configuration files.

```r
results <- automated_archive("my_config.json")
```

### Scenario 4: Development/Testing
Test with smaller datasets and validation.

```r
test_result <- test_archive_system()
```

## 🔧 Path Configuration

### Windows Paths
```r
source_path = "Z:/source/data/"
archive_root = "Z:/archive/"
staging_root = "Z:/staging/"
```

### WSL/Linux Paths
```r
source_path = "/mnt/z/source/data/"
archive_root = "/mnt/z/archive/" 
staging_root = "/mnt/z/staging/"
```

## 📚 Documentation Levels

1. **This README** - Quick reference and common patterns
2. **`config.R`** - Executable examples with inline comments
3. **`config_documentation.Rmd`** - Comprehensive guide with:
   - Detailed explanations
   - Pattern testing examples
   - Performance optimization
   - Integration examples
   - Troubleshooting guide

## ⚡ Performance Tips

- Enable `use_parallel_processing = TRUE` for large datasets
- Increase `max_workers` based on your system capabilities
- Use `quick_comparison_mode = TRUE` for faster processing
- Set appropriate `batch_size` for memory management
- Enable `cache_management` for automated cleanup

## 🔍 Troubleshooting Quick Fixes

| Problem | Solution |
|---------|----------|
| Path not found | Check WSL mounting: `ls /mnt/z/` |
| Permission denied | Verify R has write access to staging/archive |
| Pattern not matching | Test with: `grepl(pattern, test_path)` |
| Slow performance | Enable parallel processing |
| Memory issues | Reduce batch_size, enable cache cleanup |

## 🔗 Related Files

- **Main Functions**: [`../dataroom_functions.R`](../dataroom_functions.R)
- **Performance**: [`../performance_functions.R`](../performance_functions.R)  
- **Orchestrator**: [`../incremental_archive.Rmd`](../incremental_archive.Rmd)
- **Full Documentation**: [`config_documentation.Rmd`](config_documentation.Rmd)

---

## 📞 Support

For detailed explanations and advanced usage, see:
1. **Rich Documentation**: Knit `config_documentation.Rmd` to HTML
2. **Inline Comments**: Review `config.R` for implementation details
3. **Main Documentation**: See project root `README.md`

**Quick Test**: `source("examples/config.R")` should load without errors if everything is set up correctly.