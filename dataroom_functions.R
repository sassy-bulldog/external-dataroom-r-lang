#' Underwriting Data Room Archive Functions
#' 
#' This file contains the core functionality for archiving U/W source files
#' in the external data room, extracted from the original script to allow
#' for parameterized execution.

#' Archive Underwriting Files
#'
#' This function archives underwriting source files by comparing current files
#' with those already in the archive, identifying new and modified files,
#' and copying them to appropriate staging directories.
#'
#' @param current_period Character string for the current period (e.g., "2025Q2")
#' @param run_staging_directory Path to deposit intermediate files
#' @param output_staging_directory Path to deposit output archive files  
#' @param source_directory Path to current u/w source files to be archived
#' @param archive_directory Final archive directory path
#' @param archive_staging_directory Path to read current archive files from
#' @param remove_working_files Logical, whether to exclude "Working Files" directories
#' @return List containing summary information about the archiving process
#' @export
archive_underwriting_files <- function(
  current_period,
  run_staging_directory,
  output_staging_directory,
  source_directory,
  archive_directory,
  archive_staging_directory,
  remove_working_files = TRUE
) {
  
  # Load required libraries
  library(fs) 
  library(tidyverse)
  library(stringr)
  library(lubridate)
  
  # Set working directory
  original_wd <- getwd()
  on.exit(setwd(original_wd))
  setwd(run_staging_directory)
  
  # Helper function to get file info using PowerShell
  get_file_info_ps <- function(inspect_dir, out_file_name, path = getwd()) {
    cmd <- str_glue( 
      "pwsh -Command \"$ans=Get-ChildItem -LiteralPath '\\\\?\\{{inspect_dir}}' -Directory | ForEach-Object  {{ ; ",
      "$inner_dir=Convert-Path -LiteralPath $_.FullName;", 
      "Get-ChildItem -LiteralPath $inner_dir -R -File | ForEach-Object -ThrottleLimit 5 -Parallel {{",
      "$x=Convert-Path -LiteralPath $_.FullName;", 
      "[PSCustomObject]@{{Length=$_.Length ; ",
      "FullName=$_.FullName ; ",
      "LastWriteTime = $_.LastWriteTime",
      "}} }} }}; Start-Sleep -Milliseconds 100; $ans | Export-Csv '{{getwd()}}/{{out_file_name}}.txt' -Encoding ASCII\"", 
      .open = '{{', .close = '}}'
    )
    
    message(str_glue("Inspecting: {inspect_dir}; Output to: {out_file_name}"))
    shell(cmd, mustWork = TRUE, intern = TRUE)
  }
  
  # Helper function to get directory info using PowerShell
  dir_info_ps <- function(path) {
    path <- normalizePath(path, mustWork = TRUE)
    tf_dir_info <- tempfile(fileext = 'txt')
    on.exit(unlink(tf_dir_info))
    
    shell(str_glue('pwsh -Command "Get-ChildItem -LiteralPath \'{path}\' | Select Attributes, FullName| Export-Csv {tf_dir_info}" '))
    read_csv(tf_dir_info, show_col_types = FALSE)
  }
  
  # Collect info on archive files
  message("Collecting archive file information...")
  jj <- 0
  for(i in dir_ls(archive_staging_directory, type = 'directory')) {
    for(j in dir_ls(i, type = 'directory')) {
      jj <- jj + 1
      get_file_info_ps(
        inspect_dir = normalizePath(j, mustWork = TRUE), 
        out_file_name = str_glue('RAW_INFO_current_archive_{jj}')
      )
    }
    Sys.sleep(5)
  }
  Sys.sleep(15)
  
  # Combine archive file information
  arch_files <- dir_ls(glob = 'RAW_INFO_current_archive_*', type = 'file')
  current_archive_data_00 <- read_csv(arch_files[1])
  if(length(arch_files) > 1) {
    for(jj in arch_files[-1]) {
      current_archive_data_00 <- bind_rows(current_archive_data_00, read_csv(jj))
    }
  }
  write_csv(current_archive_data_00, 'RAW_INFO_current_archive.txt')
  
  # Collect info on current files
  message("Collecting source file information...")
  Sys.sleep(30)
  get_file_info_ps(
    inspect_dir = normalizePath(source_directory, mustWork = TRUE), 
    out_file_name = 'RAW_INFO_source_directory'
  )
  Sys.sleep(30)
  
  # Process archive data
  message("Processing file information...")
  current_archive_data <- read_csv('RAW_INFO_current_archive.txt') %>%
    mutate(file_id = paste0('arch_', 1:n())) %>%
    mutate(
      FullName = gsub(paste0('^', str_escape('\\\\?\\')), '', FullName),
      FullName = gsub('\\', '/', FullName, fixed = TRUE),
      period = gsub(paste0('(', archive_staging_directory, ')', '([^/]*)(/)(.*)'), '\\2', FullName),
      rel_path = gsub(paste0('(', archive_staging_directory, ')', '([^/]*)(/)'), '<root>/', FullName),
      rel_path_star = gsub('(<root>)(/)([^/]*)(.*)', '\\1\\2*\\4', rel_path),
      rel_path_wo_file = gsub('([^/]*)$', '<file>', rel_path),
      rel_path_star_wo_file = gsub('([^/]*)$', '<file>', rel_path_star),
      file_name = gsub('([^/]+[/])*([^/]*)($)', '\\2', rel_path),
      class_segment_deal = gsub("(<root>)(/)([^/]*)(/)([^/]*)(/)([^/]*)(.*)", "\\3/\\5/\\7", rel_path),
      age = 'ARCHIVE'
    ) %>%
    separate(class_segment_deal, c('class', 'segment', 'deal'), '/')
  
  # Process source data
  source_data <- read_csv('RAW_INFO_source_directory.txt') %>%
    mutate(file_id = paste0('source_', 1:n())) %>%
    mutate(
      FullName = gsub(paste0('^', str_escape('\\\\?\\')), '', FullName),
      FullName = gsub('\\', '/', FullName, fixed = TRUE),
      rel_path = gsub(source_directory, '<root>/', FullName, fixed = TRUE),
      rel_path_star = gsub(source_directory, '<root>/*/', FullName, fixed = TRUE),
      rel_path_wo_file = gsub('([^/]*)$', '<file>', rel_path),
      rel_path_star_wo_file = gsub('([^/]*)$', '<file>', rel_path_star),
      file_name = gsub('([^/]+[/])*([^/]*)($)', '\\2', rel_path),
      segment_deal = gsub("(<root>)(/)([^/]*)(/)([^/]*)(.*)", "\\3/\\5", rel_path),
      period = current_period,
      age = 'SOURCE'
    ) %>%
    separate(segment_deal, c('segment', 'deal'), '/')
  
  # Filter working files if requested
  if(remove_working_files) {
    source_data2 <- source_data %>%
      mutate(x = gsub('(<root>/\\*/)([^/]*)(/)([^/]*)(/)(.*)', '\\6', rel_path_star)) %>% 
      filter(!grepl("^Working Files/", x, ignore.case = TRUE)) %>%
      select(-x)
  } else {
    source_data2 <- source_data
  }
  
  # Process archive data to get latest versions
  current_archive_data2 <- current_archive_data %>%
    group_by(segment, deal) %>%
    mutate(original_segment_deal_period = min(period)) %>%
    filter(period == max(period)) %>%
    ungroup()
  
  # Combine data
  data <- bind_rows(source_data2, current_archive_data2)
  
  data2 <- data %>%
    group_by(segment, deal) %>%
    mutate(
      min_segment_deal_period = min(period), 
      original_segment_deal_period = min(coalesce(original_segment_deal_period, current_period))
    ) %>%
    group_by(rel_path_star, LastWriteTime, Length) %>%
    mutate(min_file_period = min(period))
  
  # Identify modified files
  message("Identifying modified files...")
  mod_files <- data2 %>%
    filter(
      age == 'SOURCE', 
      min_file_period == period, 
      period != min_segment_deal_period
    )
  
  # Search for what changed - name matches
  name_match <- mod_files %>%
    inner_join(
      data2 %>% filter(age != 'SOURCE'),
      by = c('segment', 'deal', 'rel_path_star'),
      relationship = 'one-to-one',
      suffix = c('', '__prior_name')
    ) %>%
    select(names(mod_files), 'LastWriteTime__prior_name', 'Length__prior_name', 'file_id__prior_name')
  
  # Search for renamed files
  possible_info_match <- mod_files %>%
    inner_join(
      data2 %>% filter(age != 'SOURCE'),
      by = c('segment', 'deal', 'rel_path_star_wo_file', 'Length', 'LastWriteTime'),
      relationship = 'one-to-one', 
      suffix = c('', '__prior_info')
    ) %>%
    select(names(mod_files), 'FullName__prior_info', 'rel_path__prior_info', 'rel_path_star__prior_info', 'file_id__prior_info')
  
  # Hash comparison for renamed files
  if(nrow(possible_info_match) > 0) {
    cmd0 <- possible_info_match %>%
      str_glue_data("@{{ FullName='{FullName}'; FullName__prior_info='{FullName__prior_info}' }}") %>%
      paste0(collapse = ', ')
    
    cmd1 <- str_glue('@({cmd0})')
    
    cmd <- str_glue( 
      "{{cmd1}} | ForEach-Object {{ ; ",
      "$x=Convert-Path -LiteralPath $_['FullName'];", 
      "$y=Convert-Path -LiteralPath $_['FullName__prior_info'];", 
      "$currenthash = Get-FileHash -Algorithm MD5 -LiteralPath $x  | Select-Object -ExpandProperty Hash ;",
      "$priorhash = Get-FileHash -Algorithm MD5 -LiteralPath $y  | Select-Object -ExpandProperty Hash ;",
      "[PSCustomObject]@{{",
      "FullName=$_['FullName'] ; ",
      "FullName__prior_info=$_['FullName__prior_info'] ; ",
      "Hash = $currenthash;",
      "FullName__prior_info_Hash = $priorhash;}} }} ",
      "| Export-Csv '{{getwd()}}/hash.txt' -Encoding ASCII",
      .open = '{{', .close = '}}'
    )
    
    tf <- tempfile(pattern = 'script', fileext = '.ps1')
    cat(cmd, file = tf)
    shell(str_glue('pwsh {tf} '), mustWork = TRUE, intern = TRUE)
    
    hash_info <- read_csv(file.path(getwd(), 'hash.txt'))
    
    info_match <- possible_info_match %>%
      inner_join(hash_info, by = c('FullName', 'FullName__prior_info'), relationship = 'one-to-one') %>%
      filter(Hash == FullName__prior_info_Hash)
  } else {
    info_match <- possible_info_match[0, ]
  }
  
  # Summarize changes
  name_match2 <- if(nrow(name_match) > 0) {
    name_match %>%
      mutate(mod_info_summary = str_glue('\t-) "{rel_path}" changed Size and LastWriteTime {Length__prior_name}=>{Length} and {LastWriteTime__prior_name}=>{LastWriteTime}')) %>%
      group_by(segment, deal) %>%
      summarise(
        n_mod_info = n(),
        mod_info_summary = paste0(mod_info_summary, collapse = '\n'),
        .groups = 'drop'
      )
  } else {
    tibble(segment = character(), deal = character(), n_mod_info = integer(), mod_info_summary = character())
  }
  
  info_match2 <- if(nrow(info_match) > 0) {
    info_match %>%
      mutate(mod_name_summary = str_glue('\t-) "{rel_path__prior_info}" is likely now named \n\t  "{rel_path}" as the Size ({Length}), LastWriteTime ({LastWriteTime}), and Hash match.')) %>% 
      group_by(segment, deal) %>%
      summarise(
        n_mod_name = n(),
        mod_name_summary = paste0(mod_name_summary, collapse = '\n'),
        .groups = 'drop'
      )
  } else {
    tibble(segment = character(), deal = character(), n_mod_name = integer(), mod_name_summary = character())
  }
  
  # Unmatched files
  unmatched <- mod_files %>%
    ungroup() %>%
    anti_join(name_match, by = c('segment', 'deal', 'rel_path_star')) %>%
    anti_join(info_match, by = c('segment', 'deal', 'rel_path_star'))
  
  unmatched2 <- if(nrow(unmatched) > 0) {
    unmatched %>%
      group_by(segment, deal) %>%
      summarise(
        n_mod_unknown = n(),
        mod_summary = paste0(rel_path, collapse = '\n'),
        .groups = 'drop'
      )
  } else {
    tibble(segment = character(), deal = character(), n_mod_unknown = integer(), mod_summary = character())
  }
  
  # Classify deals
  message("Classifying deals...")
  new_deals <- data2 %>%
    filter(
      age == 'SOURCE',
      min_file_period == period,
      period == min_segment_deal_period
    ) %>%
    ungroup() %>%
    select(period, original_segment_deal_period, segment, deal) %>%
    distinct()
  
  mod_deals <- if(nrow(mod_files) > 0) {
    mod_files %>%
      ungroup() %>%
      group_by(period, original_segment_deal_period, segment, deal) %>%
      summarise(n_mod_or_add_files = n(), .groups = 'drop') %>%
      ungroup()
  } else {
    tibble(period = character(), original_segment_deal_period = character(), 
           segment = character(), deal = character(), n_mod_or_add_files = integer())
  }
  
  old_deals <- data2 %>%
    filter(age != 'SOURCE') %>%
    anti_join(mod_deals, by = c('segment', 'deal')) %>%
    anti_join(new_deals, by = c('segment', 'deal')) %>%
    ungroup() %>%
    select(period, original_segment_deal_period, segment, deal, class) %>%
    distinct()
  
  # Detailed mod deals summary
  mod_deals2 <- if(nrow(mod_deals) > 0) {
    mod_deals %>%
      left_join(name_match2, by = c('segment', 'deal')) %>%
      left_join(info_match2, by = c('segment', 'deal')) %>%
      left_join(unmatched2, by = c('segment', 'deal')) %>%
      mutate(
        n_unexplained = n_mod_unknown,
        mod_summary = str_glue(
          'In total {n_mod_or_add_files} files appear to differ from the prior period.
{coalesce(n_mod_name,0)} files were likely renamed and {coalesce(n_mod_info,0)} files were likely altered.
The remaining {coalesce(n_unexplained,0)} files could be new additions or map to older files in more complex ways.

Likely renamed files: 
{coalesce(mod_name_summary, "")}.

Likely altered files: 
{coalesce(mod_info_summary, "")}.

Unexplained files: 
{coalesce(mod_summary, "")}.'))
      %>%
      select(period, original_segment_deal_period, segment, deal, n_mod_or_add_files, n_mod_name, n_mod_info, n_unexplained, mod_summary)
  } else {
    tibble(period = character(), original_segment_deal_period = character(), 
           segment = character(), deal = character(), n_mod_or_add_files = integer(),
           n_mod_name = integer(), n_mod_info = integer(), n_unexplained = integer(), mod_summary = character())
  }
  
  # Populate staging area
  message("Populating staging area...")
  copy_info <- tribble(~segment, ~from, ~to)
  
  Sys.sleep(5)
  dir_create(file.path(output_staging_directory, 'NEW'))
  Sys.sleep(5)
  
  # Copy new files
  if(nrow(new_deals) > 0) {
    for(row_i in 1:nrow(new_deals)) {
      segment_i <- new_deals$segment[row_i]
      deal_i <- new_deals$deal[row_i]
      
      deal_files_folders_i <- dir_info_ps(normalizePath(file.path(source_directory, segment_i, deal_i)))
      
      for(jj in 1:nrow(deal_files_folders_i)) {
        type_i <- deal_files_folders_i[jj, 'Attributes']
        name_i <- tail(path_split(deal_files_folders_i[jj, 'FullName'])[[1]], 1)
        
        if(type_i != 'Directory') {
          copy_info <- copy_info %>%
            bind_rows(tribble(
              ~segment, ~from, ~to,
              segment_i,
              normalizePath(file.path(source_directory, segment_i, deal_i, name_i), mustWork = FALSE),
              normalizePath(file.path(output_staging_directory, 'NEW', segment_i, deal_i), mustWork = FALSE)
            ))
        } else if(remove_working_files && type_i == 'Directory' && grepl('Working Files', name_i, ignore.case = TRUE)) {
          next
        } else {
          copy_info <- copy_info %>%
            bind_rows(tribble(
              ~segment, ~from, ~to,
              segment_i,
              normalizePath(file.path(source_directory, segment_i, deal_i, name_i), mustWork = FALSE),
              normalizePath(file.path(output_staging_directory, 'NEW', segment_i, deal_i, name_i), mustWork = FALSE)
            ))
        }
      }
    }
  }
  
  # Create MOD directory and copy modified files
  dir_create(file.path(output_staging_directory, 'MOD'))
  Sys.sleep(5)
  
  if(nrow(mod_deals2) > 0) {
    for(row_i in 1:nrow(mod_deals2)) {
      segment_i <- mod_deals2$segment[row_i]
      deal_i <- mod_deals2$deal[row_i]
      
      deal_files_folders_i <- dir_info_ps(normalizePath(file.path(source_directory, segment_i, deal_i)))
      
      for(jj in 1:nrow(deal_files_folders_i)) {
        type_i <- deal_files_folders_i[jj, 'Attributes']
        name_i <- tail(path_split(deal_files_folders_i[jj, 'FullName'])[[1]], 1)
        
        if(type_i != 'Directory') {
          copy_info <- copy_info %>%
            bind_rows(tribble(
              ~segment, ~from, ~to,
              segment_i,
              normalizePath(file.path(source_directory, segment_i, deal_i, name_i), mustWork = FALSE),
              normalizePath(file.path(output_staging_directory, 'MOD', segment_i, deal_i), mustWork = FALSE)
            ))
        } else if(remove_working_files && type_i == 'Directory' && grepl('Working Files', name_i, ignore.case = TRUE)) {
          next
        } else {
          copy_info <- copy_info %>%
            bind_rows(tribble(
              ~segment, ~from, ~to,
              segment_i,
              normalizePath(file.path(source_directory, segment_i, deal_i, name_i), mustWork = FALSE),
              normalizePath(file.path(output_staging_directory, 'MOD', segment_i, deal_i, name_i), mustWork = FALSE)
            ))
        }
      }
    }
  }
  
  # Execute file copying
  message("Copying files...")
  if(nrow(copy_info) > 0) {
    Sys.sleep(5)
    
    cmd0 <- copy_info %>%
      mutate(pws_dict = str_glue("@{{from = '\\\\?\\{from}';to = '\\\\?\\{to}' }}")) %>% 
      group_by(segment) %>%
      summarise(x = paste0(pws_dict, collapse = ','), .groups = 'drop') %>%
      mutate(x = str_glue("@({x})")) %>%
      summarise(x = paste0(x, collapse = ','), .groups = 'drop') %>%
      pull(x)
    
    cmd1 <- str_glue('@( {cmd0} )')
    cmdx <- paste0(
      "if (-not (Test-Path -LiteralPath \"$dst\")) { New-Item -ItemType Directory -Path \"$dst\" | Out-Null }; ",
      "if (Test-Path -LiteralPath \"$src\" -PathType Leaf) {",
      "$tgt = Join-Path $dst (Split-Path $src -Leaf);",
      "Copy-Item -LiteralPath $src -Destination $tgt -Force;",
      "}else{",
      "Get-ChildItem -LiteralPath \"$src\" -Recurse -File | ForEach-Object {;",
      "$rel=$_.FullName.Substring(($src).Length); $tgt=($dst)+''+$rel; ",
      "$dir=Split-Path $tgt; if (-not (Test-Path -LiteralPath $dir)) { ",
      "New-Item -ItemType Directory -Path $dir -Force | Out-Null }; ",
      "$x=Convert-Path -LiteralPath $_.FullName;",
      "Copy-Item -LiteralPath $x -Destination $tgt -Force};}"
    )
    
    cmd2 <- str_glue('$z = {cmd1}; $z | ForEach-Object -ThrottleLimit 2 -Parallel {{Write-Host "On New Item:"; $y=$_; $y | ForEach-Object  {{$src=$_[\'from\'];$dst=$_[\'to\']; Write-Host "Copying: $src To: $dst"; {cmdx}; Start-Sleep -Milliseconds 500 }} }} ')
    
    tf <- tempfile(pattern = "script", fileext = '.ps1')
    cat(cmd2, file = tf)
    shell(str_glue('pwsh "{tf}"'), mustWork = TRUE, intern = TRUE)
  }
  
  # Write file directories
  message("Writing file directories...")
  bind_rows(
    new_deals %>% mutate(class = "NEW"), 
    mod_deals2 %>% mutate(class = "MOD", period = current_period), 
    old_deals
  ) %>%
    rowwise() %>%
    mutate(
      rel_path = if_else(
        period == current_period, 
        file.path('<out_root>', class, segment, deal),
        file.path('<archive_root>', period, class, segment, deal)
      ),
      link = paste0(
        '=HYPERLINK("',
        'https://jaffacorp.egnyte.com/', 
        'navigate/path/', 
        gsub(
          '^<(out|archive)_root>/',
          gsub('^Z:/', '', if_else(
            period == current_period, 
            output_staging_directory, 
            archive_staging_directory
          )), 
          rel_path
        ), 
        '")'
      )
    ) %>% 
    write_csv(str_glue('{current_period}_Staging_Directory.csv'))
  
  bind_rows(
    new_deals %>% mutate(class = "NEW"), 
    mod_deals2 %>% mutate(class = "MOD", period = current_period), 
    old_deals
  ) %>%
    mutate(
      rel_path = file.path('<root>', period, class, segment, deal),
      link = paste0(
        '=HYPERLINK("',
        'https://jaffacorp.egnyte.com/', 
        'navigate/path/', 
        gsub(
          '^<root>/',
          gsub('^Z:/', '', archive_directory), 
          rel_path
        ), 
        '")'
      )
    ) %>% 
    write_csv(str_glue('{current_period}_Directory.csv'))
  
  message("Archive process completed successfully!")
  
  # Return summary information
  list(
    new_deals = new_deals,
    mod_deals = mod_deals2,
    old_deals = old_deals,
    files_copied = nrow(copy_info),
    current_period = current_period
  )
}