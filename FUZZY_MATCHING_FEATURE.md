# Fuzzy Matching Feature for Renamed-and-Modified Files

## Overview
The fuzzy matching feature identifies files that may have been both renamed AND modified between quarters. Since MD5 hashes won't match when file content changes, these files would normally appear as one "REMOVED" file and one "NEW" file. The fuzzy matcher uses file characteristics to suggest potential pairs for human review.

## How It Works

### Scoring Algorithm
For each pair of NEW and REMOVED files, the system calculates a match score (0-100) based on:

1. **File Extension Match (25 points)**
   - Exact match of file extension (e.g., `.xlsx`, `.pdf`)

2. **File Name Similarity (30 points)**
   - Uses Levenshtein distance to compare file names
   - Normalized by the longest name length

3. **Size Similarity (20 points)**
   - Files within 20% of each other's size score highly
   - Accounts for minor modifications that slightly change file size

4. **Directory Similarity (15 points)**
   - Compares directory paths for common components
   - Higher score if files are in similar folder structures

5. **Modified Time Proximity (10 points)**
   - Files modified within 30 days score points
   - Closer dates score higher

### Threshold and Flagging
- **Default Threshold**: 80 (configurable via `fuzzy_match_threshold` parameter)
- **Behavior**:
  - ALL new and removed files get a "best match candidate" and score
  - Only pairs scoring >= threshold are flagged with `potential_rename_modify = TRUE`
  - Lower-scoring pairs are still recorded for human review

## Output Files

### 1. File Summary CSV (`{quarter}_file_summary.csv`)
Includes fuzzy match columns for NEW files:
- `potential_rename_modify`: TRUE if score >= threshold
- `suggested_original_file`: Path to the best-matching removed file
- `match_confidence_score`: Score (0-100)

### 2. Removed Files CSV (`{quarter}_removed_files.csv`)
Includes fuzzy match columns for REMOVED files:
- `potential_rename_modify`: TRUE if score >= threshold
- `suggested_new_file`: Path to the best-matching new file
- `match_confidence_score`: Score (0-100)

### 3. Fuzzy Match Pairs CSV (`{quarter}_fuzzy_match_pairs.csv`) ⭐ **NEW**
Consolidated view of all potential pairs, sorted by score:

```csv
match_confidence_score,flagged_as_potential,removed_file,removed_file_name,removed_size,removed_modified_time,removed_category_1,removed_category_2,suggested_new_file,new_file_name,new_size,new_modified_time,new_category_1,new_category_2
62.1,FALSE,Branch/PPA-HO 2023 Q2/Branch Insurance...,Branch Insurance Claim Loss Development...,56217,2024-01-09 13:54:34,Branch,PPA-HO 2023 Q2,Relm/Professional Liab - Crypto - Jun 2023/...,Relm Digital Assets - LR Analysis - 2023.xlsm,754030,2023-05-19 14:34:35,Relm,Professional Liab - Crypto - Jun 2023
```

**Columns:**
- `match_confidence_score`: Score (0-100)
- `flagged_as_potential`: TRUE if score >= 80
- `removed_file`: Path to removed file
- `removed_file_name`, `removed_size`, `removed_modified_time`: Removed file details
- `removed_category_1`, `removed_category_2`: Removed file categories
- `suggested_new_file`: Path to suggested new file
- `new_file_name`, `new_size`, `new_modified_time`: New file details
- `new_category_1`, `new_category_2`: New file categories

## Example Test Results (2024Q3)

### Summary
- **Total pairs evaluated**: 47 removed × 170 new = 7,990 combinations
- **Pairs with scores recorded**: 47 (best match for each removed file)
- **Pairs flagged as potential (score >= 80)**: 0
- **Top score**: 62.1

### Top Suggested Pairs
| Score | Removed File | Suggested New File |
|-------|--------------|-------------------|
| 62.1 | Branch/PPA-HO 2023 Q2/Branch Insurance... | Relm/Professional Liab... |
| 61.0 | Branch/PPA-HO 2023 Q2/JE Parallelogram... | Branch/PPA-HO August 2024/Loss... |
| 60.0 | Redstone/GL - Jan 2023/JE ULR RCGL... | QEO/CA - 2023/Source Material... |

### Interpretation
With a threshold of 80, **no pairs were automatically flagged**, which is correct - these files are genuinely different and just happen to have some similarity in names or characteristics. The user confirmed that the top-scoring pairs (60-62) are NOT the same files, validating the threshold choice.

## Usage

### In Code
```r
# Default threshold of 80
result <- compare_snapshots(current_metadata, previous_metadata)

# Custom threshold
result <- compare_snapshots(current_metadata, previous_metadata, 
                           fuzzy_match_threshold = 70)  # More lenient

result <- compare_snapshots(current_metadata, previous_metadata, 
                           fuzzy_match_threshold = 90)  # Stricter
```

### Sequential Processing
The feature is automatically enabled when using `process_quarters_sequentially()`:
```r
source("sequential_processing.R")
result <- process_quarters_sequentially(quarters = c("2024Q1", "2024Q2", "2024Q3"))
```

## Review Workflow

1. **Check Flagged Pairs**
   - Look for `flagged_as_potential = TRUE` in the fuzzy match pairs CSV
   - These are high-confidence matches (score >= 80) that likely need reclassification

2. **Review Top Scores**
   - Sort by `match_confidence_score` descending
   - Review pairs with scores 70-79 (just below threshold)
   - Use judgment to decide if they're the same file

3. **Manual Reclassification** (if needed)
   - If a pair is confirmed as rename-and-modify:
     - Move from NEW/REMOVED to a "RENAMED_AND_MODIFIED" category
     - Update metadata accordingly
   - If uncertain, leave as-is and document for team review

## Configuration

### Adjusting the Threshold
- **Lower (60-70)**: More sensitive, catches more potential matches, but more false positives
- **Default (80)**: Balanced - only flags high-confidence matches
- **Higher (85-95)**: Very conservative, only extremely obvious matches

### Modifying Scoring Weights
Edit `calculate_fuzzy_match_score()` in `dataroom_functions.R` to adjust:
- Extension weight (currently 25 points)
- Name similarity weight (currently 30 points)
- Size similarity weight (currently 20 points)
- Directory similarity weight (currently 15 points)
- Time proximity weight (currently 10 points)

## Benefits

1. **Catch Edge Cases**: Identifies files that were renamed AND modified (MD5 mismatch)
2. **Reduce Manual Review**: Automated scoring highlights likely matches
3. **Audit Trail**: All suggestions recorded even if below threshold
4. **Human Oversight**: Flagging (not automatic reclassification) requires review
5. **Documentation**: Consolidated pairs CSV makes review efficient

## Limitations

1. **Computational Cost**: Compares every NEW file to every REMOVED file (N×M complexity)
2. **No Guarantee**: Scoring is heuristic - human judgment required
3. **Single Best Match**: Each file only gets ONE suggested match (highest scoring)
4. **Content Blind**: Doesn't examine file contents, only metadata

## Future Enhancements

1. **Performance Optimization**
   - Add early termination for very low scores
   - Implement caching for repeated comparisons

2. **Enhanced Scoring**
   - Add file type-specific scoring rules
   - Consider directory depth and folder name patterns
   - Weight by file size class (large files = more confident matching)

3. **Interactive Review Tool**
   - R Shiny app to review and accept/reject suggestions
   - Bulk operations for confirmed matches

4. **Machine Learning**
   - Train on confirmed matches to improve scoring
   - Learn organization-specific file naming patterns

---

## Summary

The fuzzy matching feature provides **intelligent suggestions** for files that may have been renamed and modified, helping reviewers catch cases that exact MD5 matching would miss. With a conservative default threshold of 80, it minimizes false positives while still recording all candidate pairs for review.
