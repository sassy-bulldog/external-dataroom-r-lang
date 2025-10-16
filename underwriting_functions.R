#' ---
#' title: U/W Folder Data Room Archive
#' author: Chris Laws
#' output: 
#'   html_document:
#'    toc: true
#'    toc_depth: 2
#'    toc_float: true
#'    number_sections: true
#' ---
#' 
#' # Overview
#' 
#' ## Purpose
#' This script was created to incrementally archive U/W source files in the external data room.
#' 
#' U/W source files generally do not change once they are finalized.
#' And so the script builds a view of the the U/W source files by:
#'  1. Referencing files already in the archive
#'  2. Adding new files to the archive
#'  3. Coping any modified files into the archive.
#' The script looks to help focus the archive user toward new/modified files while providing easy access to previously existing files.
#' 
#' ## Approach
#' The script compares the current set of U/W source files to those already in the archive.
#' If the (relative) path, file name, last write time, and size already exist in the archive; the file is assumed unchanged.
#' Otherwise, the file is assumed to be new/modified and archived file (and associated files) are considered invalid and the current files are added to the archive.
#' 
#' In the event that the file may have existed before, the script tries to summarize what may have changed.
#' * The script tries to identify files that have the same (relative) path and name, but may have been modified because the last write time and size have changed.
#' * The script tries to identify files that may have been renamed by first comparing the (relative) path, last write time, and size.
#'    - If these qualities match, a full file hash is pulled and compared to ensure the contents are consistent between the two files with different names.
#'    
#' ## Helpful Conventions
#' - The script associates each collection of files by "segment" and "deal".
#' - The script assumes that files are stored in a hierarchical file path with a "./<segment>/<deal>/*" convention.
#' - The script *does not* look for files that have been removed. For instance, is the archive has file XYZ.csv associated with Segment A Deal 1 and the current U/W sources files have removed XYZ.csv, file XYZ.csv will not be considered when comparing the current and archived versions of Segment A Deal 1.
#' 
#' The archive structure should consist of:
#' 1. A Content folder that houses the archived U/W source files. 
#'    - The Content folder consists of a series of sub-folders.
#'    - Each sub-folder is typically named in a {YYYY}Q{Q} pattern (e.g., 2025Q2) that corresponds the period in which the files were added.
#'    - The names *must* sort in R such that max{sub-folder-name} is the most recent.
#' 2. A RunLogs folder the houses the script, logs, intermediate files, etc. used.
#'    - The Content folder consists of a series of sub-folders.
#'    - Each sub-folder is typically named in a {YYYY}Q{Q} pattern that corresponds the period in which the files were added.
#' 3. A series of archive directory files.
#'    - Each archive directory file is typically named in a {YYYY}Q{Q}_Directory.csv pattern that corresponds the period in which the files were added.
#'  
#' Note that we used powershell to get this info to avoid a max file path limitation of R packages.
#'    
#' ## Output
#' The script output is:
#' 1. A "NEW" folder that contains all "segment"x"deal"(s) that did not previously exist in the archive.
#' 2. A "MOD" folder that contains all "segment"x"deal"(s) that previously existed in the archive but now have files that did not match the archive.
#' 3. An archive directory that includes the full set of "segment"x"deal"s and helpful information such as where to locate the current archived copy and a summary of what may have changed for "segment"x"deal"s showing modified files.
#' 
#' Note that two File Directories are created.
#' One that references the path relative to the archive staging area; this directory is useful to inspect the output *before* the output is copied into the final archive area.
#' The other that references the path relative to the final archive area; this directory is useful to navigate the final archive area.
#' 
#' ## Running the Script
#' ### Step 1
#' Setup the new staging area/folder structure.
#' This can be any new/unused folder. 
#' Intermediate files, the script, and output will be initially populated into this staging area.
#' The script should be copied into this new staging folder.
#' 
#' ### Step 2
#' Adjust the values in the Input Parameters section of the code.
#' 
#' ### Step 3
#' Compile a Report of the script.
#' (Ctrl-Shift-K in R Studio)
#' The script will deposit the intermediate files, the script, and output into this staging area.
#' 
#' ### Step 4
#' After the staging area has been manually reviewed, the contents can be manually moved into the archive.
#' The NEW and MOD folders in the staging area should be copied into a newly created {YYYY}Q{Q} sub-folder of the Content folder.
#' The other files should be copied into a newly created {YYYY}Q{Q} sub-folder of the RunLogs folder.
#' The archive directory file should copied into the root of the archive (i.e., the same level as the Content and RunLogs folder).
#' 
#' 

#' # Input Parameters

#Typically named in a {YYYY}Q{Q} pattern (e.g., 2025Q2) that corresponds the period in which the files were added.
#The value *must* sort in R such that max{sub-folder-name} is the most recent.
current_period <- '2025Q2'



#The temporary location to for the script deposit the intermediate files.
run_staging_directory <- 'Z:/Shared/Jaffa Main/Insurance/Reserving and Valuations/20250630/Huggins Dataroom/Underwriting/RunLogs/2025Q2/'

#The temporary location to for the script deposit the output archive files.
#Typically set to run_staging_directory
##output_staging_directory <- run_staging_directory
output_staging_directory <- 'Z:/Shared/Jaffa Main/Insurance/Reserving and Valuations/20250630/Huggins Dataroom/Underwriting/Content/2025Q2/'

#The location of the current u/w source files to be archived.
source_directory <- 'Z:/Shared/Jaffa Main/Insurance/Reserving and Valuations/20250630/Huggins Dataroom/Underwriting/TEMP_2025Q2/'


#The final archive staging version of the archive directory will reference this location.
#Typically set to archive_staging_directory is set to the same value as archive_directory, and (as such) archive files will typically be read from here.
archive_directory <- 'Z:/Shared/Jaffa External/Huggins/Underwriting/Content/'

#Typically set to archive_directory.
#Current archive files will be read from here and the archive staging version of the archive directory will reference this location.
##archive_staging_directory <- archive_directory
archive_staging_directory <- 'Z:/Shared/Jaffa Main/Insurance/Reserving and Valuations/20250630/Huggins Dataroom/Underwriting/Content/'



#Typically set to TRUE.
#When FALSE, all files considered in comparisons and copied.
#When TRUE, any files in a sub-directory matching "Working Files" (ignoring case) are neither considered nor copied.
remove_working_files <- TRUE



#' # Initialize R

R.version
Sys.time()

library(fs) 
library(tidyverse)
library(stringr)
library(lubridate)



setwd(run_staging_directory)


#' # Collect the Info on Relevant Files

#function to loop through all files in a directory and write the size and lastwrite time out to a csv file
get_file_info_ps <- function(inspect_dir,out_file_name,path=getwd()){
  
  cmd <-
    str_glue( 
      "pwsh -Command \"$ans=Get-ChildItem -LiteralPath '\\\\?\\{{inspect_dir}}' -Directory | ForEach-Object  { ; ",
      "$inner_dir=Convert-Path -LiteralPath $_.FullName;", 
      "Get-ChildItem -LiteralPath $inner_dir -R -File | ForEach-Object -ThrottleLimit 5 -Parallel {",
      "$x=Convert-Path -LiteralPath $_.FullName;", 

      "[PSCustomObject]@{Length=$_.Length ; ",
      "FullName=$_.FullName ; ",
      
      "LastWriteTime = $_.LastWriteTime",
      
      "} } }; Start-Sleep -Milliseconds 100; $ans | Export-Csv '{{getwd()}}/{{out_file_name}}.txt' -Encoding ASCII\"", 
      .open = '{{', .close='}}')
  
  message(str_glue("Inspecting: {inspect_dir}; Output to: {out_file_name}"))
  shell(cmd, mustWork = TRUE, intern = TRUE)
  
}

#' ## Collect the Info on Archive Files

jj<-0
for(i in dir_ls(archive_staging_directory, type = 'directory')){
  for(j in dir_ls(i, type = 'directory')){
    jj<-jj + 1
    get_file_info_ps(inspect_dir=normalizePath(j, mustWork = TRUE), out_file_name = str_glue('RAW_INFO_current_archive_{jj}'))
  }
  Sys.sleep(5)
}
Sys.sleep(15)




arch_files <- dir_ls(glob='RAW_INFO_current_archive_*', type= 'file')
current_archive_data_00 <- read_csv(arch_files[1])
if(length(arch_files)>1){
  for(jj in arch_files[-1]){
    current_archive_data_00 <-
      bind_rows(current_archive_data_00,
                read_csv(jj))
  }
}
write_csv(current_archive_data_00, 'RAW_INFO_current_archive.txt')

#' ## Collect the Info on Current Files
Sys.sleep(30)
get_file_info_ps(inspect_dir=normalizePath(source_directory, mustWork = TRUE), out_file_name = 'RAW_INFO_source_directory')
Sys.sleep(30)


#' # Process Info on the Files


current_archive_data<-
  read_csv('RAW_INFO_current_archive.txt') %>%
  mutate(file_id=paste0('arch_',1:n())) %>%
  mutate(FullName=gsub(paste0('^', str_escape('\\\\?\\')), '', FullName),
         FullName=gsub('\\', '/', FullName, fixed=TRUE),
         
         
         period=gsub(paste0('(',archive_staging_directory, ')', '([^/]*)(/)(.*)'), '\\2', FullName),
         
         #rel_path removes the leading elements of a file path to make them more comparable across locations
         rel_path=gsub(paste0('(',archive_staging_directory, ')', '([^/]*)(/)'), '<root>/', FullName),
         #rel_path_star standardizes across some variants of the leading sub-directory (e.g., removes ./MOD/.)
         rel_path_star=gsub('(<root>)(/)([^/]*)(.*)', '\\1\\2*\\4', rel_path),
         
         
         #_wo_file versions remove the file name
         rel_path_wo_file=gsub('([^/]*)$', '<file>', rel_path),
         rel_path_star_wo_file=gsub('([^/]*)$', '<file>', rel_path_star),
         
         file_name=gsub('([^/]+[/])*([^/]*)($)', '\\2', rel_path),
         
         class_segment_deal=gsub("(<root>)(/)([^/]*)(/)([^/]*)(/)([^/]*)(.*)", "\\3/\\5/\\7", rel_path),
         age='ARCHIVE') %>%
  separate(class_segment_deal, c('class', 'segment', 'deal'), '/')


source_data<-
  read_csv('RAW_INFO_source_directory.txt') %>%
  mutate(file_id=paste0('source_',1:n())) %>%
  ##filter(Attributes != 'Directory') %>%
  mutate(FullName=gsub(paste0('^', str_escape('\\\\?\\')), '', FullName),
         FullName=gsub('\\', '/', FullName, fixed=TRUE),
         rel_path=gsub(source_directory, '<root>/', FullName, fixed = TRUE),
         rel_path_star=gsub(source_directory, '<root>/*/', FullName, fixed = TRUE),
         
         
         
         rel_path_wo_file=gsub('([^/]*)$', '<file>', rel_path),
         rel_path_star_wo_file=gsub('([^/]*)$', '<file>', rel_path_star),
         file_name=gsub('([^/]+[/])*([^/]*)($)', '\\2', rel_path),
         segment_deal=gsub("(<root>)(/)([^/]*)(/)([^/]*)(.*)", "\\3/\\5", rel_path),
         
         period=current_period,
         age='SOURCE') %>%
  separate(segment_deal, c('segment', 'deal'), '/')


if(remove_working_files){
  source_data2 <-
    source_data %>%
    mutate(x=gsub('(<root>/\\*/)([^/]*)(/)([^/]*)(/)(.*)', '\\6', rel_path_star)) %>% 
    filter(!grepl("^Working Files/", x, ignore.case=TRUE)) %>%
    select(-x)
} else {
  source_data2 <-
    source_data
  
}



current_archive_data2 <-
  current_archive_data %>%
  group_by(segment, deal) %>%
  #original_segment_deal_period gives the period that the segment/deal was first archived
  mutate(original_segment_deal_period=min(period)) %>%
  #there may be multiple versions of a segment/deal in the archive, this filters to only the latest version
  filter(period==max(period)) %>%
  ungroup


data <-
  bind_rows(source_data2,
            current_archive_data2)





data2 <-
  data %>%
  group_by(segment, deal) %>%
  mutate(min_segment_deal_period=min(period), 
         original_segment_deal_period=min(coalesce(original_segment_deal_period, current_period))) %>%
  
  # a "file" is defined not only by it's path and file name, but also its last write time and size/length
  group_by(rel_path_star, LastWriteTime, Length) %>%
  mutate(min_file_period=min(period)) 


#' # Identify and Describe Modified Files
#' Note that "Modified" Files includes both:
#' 1. Files that existed before but have been modified and
#' 2. Files that are newly added and didn't exist before (but for which the segment/deal is already in the archive)

mod_files<-
  data2 %>%
  filter(
    #modified files are in the current U/W file location
    age=='SOURCE', 
    min_file_period == period, 
    
    #but the segment existed before (or is in the archive)
    period != min_segment_deal_period)


#' ## Search for What Changed

#' ### Does the File Name Remain Untouched?
#' If so, the file contents have (likely) changed.
name_match <-
  mod_files %>%
  inner_join(data2 %>% filter(age!='SOURCE'),
             by=c('segment', 'deal', 'rel_path_star'),
             relationship = 'one-to-one',
             suffix = c('', '__prior_name')) %>%
  select(names(mod_files), 'LastWriteTime__prior_name', 'Length__prior_name', 'file_id__prior_name')

#' ### Was the File Renamed?
#' If so, we can identify possible original file names by looking for files that match the (relative) location, the size/length, and the lastwrite time of the file.
#' After identify the possible original file names, we will confirm matches by comparing a full file has of the binary contents.
#TODO: the code currently on works if there is only one possible match. The code will error out if there are two possible matches.
possible_info_match <-
  mod_files %>%
  inner_join(data2 %>% filter(age!='SOURCE'),
             by=c('segment', 'deal', 'rel_path_star_wo_file', 'Length', 'LastWriteTime'),
             
             #ensure there is only one possible match per file (relationship = 'one-to-one').
             #note that the code will error out if there are more than one possible matches.
             relationship = 'one-to-one', 
             suffix = c('', '__prior_info')) %>%
  select(names(mod_files), 'FullName__prior_info', 'rel_path__prior_info', 'rel_path_star__prior_info', 'file_id__prior_info')

#Pull the hash information
cmd0 <-
  possible_info_match %>%
  str_glue_data("@{{ FullName='{FullName}'; FullName__prior_info='{FullName__prior_info}' }}") %>%
  paste0( collapse = ', ')

cmd1 <-
  str_glue('@({cmd0})')

cmd <-
  str_glue( 
    "{{cmd1}} | ForEach-Object { ; ",
    
    "$x=Convert-Path -LiteralPath $_['FullName'];", 
    "$y=Convert-Path -LiteralPath $_['FullName__prior_info'];", 
    
    "$currenthash = Get-FileHash -Algorithm MD5 -LiteralPath $x  | Select-Object -ExpandProperty Hash ;",
    "$priorhash = Get-FileHash -Algorithm MD5 -LiteralPath $y  | Select-Object -ExpandProperty Hash ;",
    
    "[PSCustomObject]@{",
    "FullName=$_['FullName'] ; ",
    "FullName__prior_info=$_['FullName__prior_info'] ; ",

    "Hash = $currenthash;",
    "FullName__prior_info_Hash = $priorhash;} } ",
    "| Export-Csv '{{getwd()}}/hash.txt' -Encoding ASCII",
    .open = '{{', .close='}}')

tf <-tempfile(pattern = 'script', fileext = '.ps1')
cat(cmd, file = tf)
shell(str_glue('pwsh {tf} '), mustWork = TRUE, intern = TRUE)

hash_info <- read_csv(file.path(getwd(), 'hash.txt'))


info_match <-
  possible_info_match %>%
  inner_join(hash_info, 
             by=c('FullName', 'FullName__prior_info'),
             relationship = 'one-to-one')


#error check that joining the hash info did not change the number of possible matches
stopifnot(
  info_match %>% nrow ==
    possible_info_match %>% nrow)

#filter out possible_info_matches that do not share the same file hash as the original  
info_match <-
  info_match %>%
  filter(Hash == FullName__prior_info_Hash)


stopifnot(
  0 ==
    intersect(name_match$file_id,
              info_match$file_id),
  0 ==
    intersect(name_match$file_id__prior_name,
              info_match$file_id__prior_info),
  !any(duplicated(name_match$file_id)),
  !any(duplicated(name_match$file_id__prior_name)),

  !any(duplicated(info_match$file_id)),
  !any(duplicated(info_match$file_id__prior_info)))

#' ## Summarize the Likely Changes
name_match2 <-
  name_match %>%
  mutate(mod_info_summary=str_glue('\t-) "{rel_path}" changed Size and LastWriteTime {Length__prior_name}=>{Length} and {LastWriteTime__prior_name}=>{LastWriteTime}')) %>%
  group_by(segment, deal) %>%
  summarise(n_mod_info=n(),
            mod_info_summary=paste0(mod_info_summary, collapse = '\n'))

info_match2 <-
  info_match %>%
  mutate(mod_name_summary=str_glue('\t-) "{rel_path__prior_info}" is likely now named \n\t  "{rel_path}" as the Size ({Length}), LastWriteTime ({LastWriteTime}), and Hash match.')) %>% 
  group_by(segment, deal) %>%
  summarise(n_mod_name=n(),
            mod_name_summary=paste0(mod_name_summary, collapse = '\n'))

#' ## Summarize the Unknown Changes
unmatched <-
  mod_files %>%
  ungroup() %>%
  anti_join(name_match, by=c('segment', 'deal', 'rel_path_star'))  %>%
  anti_join(info_match, by=c('segment', 'deal', 'rel_path_star'))

unmatched2 <-
  unmatched %>%
  group_by(segment, deal) %>%
  summarise(n_mod_unknown=n(),
            mod_summary=paste0(rel_path, collapse = '\n'))


#' # Classify All Segment/Deals

#new deals are those that did not already exist in the archive
new_deals <-
  data2 %>%
  filter(age=='SOURCE',
         min_file_period == period,
         period == min_segment_deal_period) %>%
  ungroup() %>%
  select(period, original_segment_deal_period, segment, deal) %>%
  distinct()

#mod deals are those that did already exist in the archive but now show a change
mod_deals <-
  mod_files %>%
  ungroup %>%
  ##select(period, segment, deal) %>%
  group_by(period, original_segment_deal_period, segment, deal) %>%
  summarise(n_mod_or_add_files=n()) %>%
  ungroup()



old_deals <-
  data2 %>%
  filter(age != 'SOURCE') %>%
  anti_join(mod_deals, by=c('segment', 'deal')) %>%
  anti_join(new_deals, by=c('segment', 'deal')) %>%
  ungroup() %>%
  select(period, original_segment_deal_period, segment, deal, class) %>%
  distinct()


mod_deals2 <-
  mod_deals %>%
  left_join(name_match2, by=c('segment', 'deal')) %>%
  left_join(info_match2, by=c('segment', 'deal')) %>%
  left_join(unmatched2, by=c('segment', 'deal')) %>%
  mutate(n_unexplained=n_mod_unknown,
         mod_summary=str_glue(
           'In total {n_mod_or_add_files} files appear to differ from the prior period.
{coalesce(n_mod_name,0)} files were likely renamed and {coalesce(n_mod_info,0)} files were likely altered.
The remaining {coalesce(n_unexplained,0)} files could be new additions or map to older files in more complex ways.

Likely renamed files: 
{coalesce(mod_name_summary, "")}.

Likely altered files: 
{coalesce(mod_info_summary, "")}.
           
Unexplained files: 
{coalesce(mod_summary, "")}.')) %>%
  select(period, original_segment_deal_period, segment, deal, n_mod_or_add_files, n_mod_name, n_mod_info, n_unexplained, mod_summary)


stopifnot(0 == mod_deals2 %>% 
            filter(n_mod_or_add_files != coalesce(n_mod_name, 0) +coalesce(n_mod_info,0) + coalesce(n_unexplained, 0)) %>% 
            nrow)


#' # Populate the Staging Area

dir_info_ps <- function(path){
  path <-normalizePath(path, mustWork = TRUE)
  tf_dir_info <- tempfile(fileext = 'txt')
  on.exit(unlink(tf_dir_info))
  
  shell(str_glue('pwsh -Command "Get-ChildItem -LiteralPath \'{path}\' | Select Attributes, FullName| Export-Csv {tf_dir_info}" '))
  read_csv(tf_dir_info, show_col_types = FALSE)
  
  
}

#' ## Identify What Files to Copy Where

copy_info <- tribble(~segment, ~from, ~to)

Sys.sleep(5)
dir_create(file.path(output_staging_directory, 'NEW'))
Sys.sleep(5)




for(row_i in 1:nrow(new_deals)) {
  
  segment_i <- new_deals$segment[row_i]
  deal_i <- new_deals$deal[row_i]
  
  
  
  
  ##deal_files_folders_i <- dir_info((normalizePath(file.path(source_directory, segment_i, deal_i))))
  deal_files_folders_i <- dir_info_ps((normalizePath(file.path(source_directory, segment_i, deal_i))))
  
  for(jj in 1:nrow(deal_files_folders_i)){
    
    type_i <- deal_files_folders_i[jj, 'Attributes']
    name_i <- tail(path_split(deal_files_folders_i[jj, 'FullName'])[[1]], 1)
    
    
    if(type_i != 'Directory'){
      
      copy_info <-
        copy_info %>%
        bind_rows(tribble(~segment,
                          ~from, 
                          ~to,
                          
                          segment_i,
                          normalizePath(file.path(source_directory, segment_i, deal_i, name_i), mustWork = FALSE),
                          normalizePath(file.path(output_staging_directory, 'NEW', segment_i, deal_i), mustWork = FALSE)
                          
        ))
      
    } else if(remove_working_files && type_i == 'Directory' && grepl('Working Files', name_i, ignore.case = TRUE)){
      next
    } else {
      
      copy_info <-
        copy_info %>%
        bind_rows(tribble(~segment,
                          ~from, 
                          ~to,
                          
                          segment_i,
                          normalizePath(file.path(source_directory, segment_i, deal_i, name_i),         mustWork = FALSE),
                          normalizePath(file.path(output_staging_directory, 'NEW', segment_i, deal_i, name_i), mustWork = FALSE)
                          
        ))
      
    }
    #Sys.sleep(1)  
  }
  #Sys.sleep(5)
  
}

Sys.sleep(5)
dir_create(file.path(output_staging_directory, 'MOD'))
Sys.sleep(5)




for(row_i in 1:nrow(mod_deals2)) {
  
  segment_i <- mod_deals2$segment[row_i]
  deal_i <- mod_deals2$deal[row_i]
  
  
  
  
  ##deal_files_folders_i <- dir_info((normalizePath(file.path(source_directory, segment_i, deal_i))))
  deal_files_folders_i <- dir_info_ps((normalizePath(file.path(source_directory, segment_i, deal_i))))
  
  for(jj in 1:nrow(deal_files_folders_i)){
    
    type_i <- deal_files_folders_i[jj, 'Attributes']
    name_i <- tail(path_split(deal_files_folders_i[jj, 'FullName'])[[1]], 1)
    
    
    if(type_i != 'Directory'){
      
      copy_info <-
        copy_info %>%
        bind_rows(tribble(~segment,
                          ~from, 
                          ~to,
                          
                          segment_i,
                          normalizePath(file.path(source_directory, segment_i, deal_i, name_i), mustWork = FALSE),
                          normalizePath(file.path(output_staging_directory, 'MOD', segment_i, deal_i), mustWork = FALSE)
                          
        ))
      
    } else if(remove_working_files && type_i == 'Directory' && grepl('Working Files', name_i, ignore.case = TRUE)){
      next
    } else {
      
      copy_info <-
        copy_info %>%
        bind_rows(tribble(~segment,
                          ~from, 
                          ~to,
                          
                          segment_i,
                          normalizePath(file.path(source_directory, segment_i, deal_i, name_i),         mustWork = FALSE),
                          normalizePath(file.path(output_staging_directory, 'MOD', segment_i, deal_i, name_i), mustWork = FALSE)
                          
        ))
      
    }
    #Sys.sleep(1)  
  }
  #Sys.sleep(5)
  
}



#' ## Do the COPY
#' Note that we build a powershell script to do the copying.
Sys.sleep(5)

cmd0 <-
  copy_info %>%
  mutate(pws_dict=str_glue("@{{from = '\\\\?\\{from}';to = '\\\\?\\{to}' }}")) %>% 
  group_by(segment) %>%
  summarise(x=paste0(pws_dict, collapse = ',')) %>%
  mutate(x=str_glue("@({x})")) %>%
  summarise(x=paste0(x, collapse = ',')) %>%
  pull(x)

cmd1 <- str_glue('@( {cmd0} )')
cmdx <- paste0("if (-not (Test-Path -LiteralPath \"$dst\")) { New-Item -ItemType Directory -Path \"$dst\" | Out-Null }; ",
               "if (Test-Path -LiteralPath \"$src\" -PathType Leaf) {",
               "$tgt = Join-Path $dst (Split-Path $src -Leaf);",
               "Copy-Item -LiteralPath $src -Destination $tgt -Force;",
               "}else{",
               "Get-ChildItem -LiteralPath \"$src\" -Recurse -File | ForEach-Object {;",
               
               "$rel=$_.FullName.Substring(($src).Length); $tgt=($dst)+''+$rel; ",
               "$dir=Split-Path $tgt; if (-not (Test-Path -LiteralPath $dir)) { ",
               "New-Item -ItemType Directory -Path $dir -Force | Out-Null }; ",
               "$x=Convert-Path -LiteralPath $_.FullName;",
               "Copy-Item -LiteralPath $x -Destination $tgt -Force};}")


cmd2 <- str_glue('$z = {cmd1}; $z | ForEach-Object -ThrottleLimit 2 -Parallel {{Write-Host "On New Item:"; $y=$_; $y | ForEach-Object  {{$src=$_[\'from\'];$dst=$_[\'to\']; Write-Host "Copying: $src To: $dst"; {cmdx}; Start-Sleep -Milliseconds 500 }} }} ')
cmd2

tf <- tempfile(pattern = "script", fileext = '.ps1')

cat(cmd2, file = tf)
shell(str_glue('pwsh "{tf}"'), mustWork = TRUE, intern = TRUE)

#' # Write the File Directory


bind_rows(new_deals %>% mutate(class="NEW"), 
          mod_deals2 %>% mutate(class="MOD", period=current_period), 
          old_deals) %>%
  rowwise() %>%
  mutate(rel_path=if_else(period==current_period, 
                          file.path('<out_root>',         class, segment, deal),
                          file.path('<archive_root>', period, class, segment, deal)),
         link=paste0('=HYPERLINK("',
                     'https://jaffacorp.egnyte.com/', 
                     'navigate/path/', 
                     
                     gsub('^<(out|archive)_root>/',
                          gsub('^Z:/', '', if_else(period==current_period, 
                                                   output_staging_directory, 
                                                   archive_staging_directory)), 
                          rel_path), 
                     '")')) %>% 
  write_csv(str_glue('{current_period}_Staging_Directory.csv'))




bind_rows(new_deals %>% mutate(class="NEW"), 
          mod_deals2 %>% mutate(class="MOD", period=current_period), 
          old_deals) %>%
  mutate(rel_path=file.path('<root>', period, class, segment, deal),
         link=paste0('=HYPERLINK("',
                     'https://jaffacorp.egnyte.com/', 
                     'navigate/path/', 
                     
                     gsub('^<root>/',
                          gsub('^Z:/', '', archive_directory), 
                          rel_path), 
                     '")')) %>% 
  write_csv(str_glue('{current_period}_Directory.csv'))
