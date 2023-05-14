use std::{fs, io, str::FromStr};

pub fn strings_equal(string1: &str, string2: &str) -> bool {
    string1 == string2
}

pub fn strings_not_equal(string1: &str, string2: &str) -> bool {
    string1 != string2
}

pub fn strings_lexographically_less_than(string1: &str, string2: &str) -> bool {
    string1 < string2
}

pub fn strings_lexographically_less_than_or_equal_to(string1: &str, string2: &str) -> bool {
    string1 <= string2
}

pub fn strings_lexographically_greater_than(string1: &str, string2: &str) -> bool {
    string1 > string2
}

pub fn strings_lexographically_greater_than_or_equal_to(string1: &str, string2: &str) -> bool {
    string1 >= string2
}

type TestParseResult = Result<bool, <i64 as FromStr>::Err>;

pub fn integers_equal(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 == integer2)
}

pub fn integers_greater_than_or_equal_to(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 >= integer2)
}

pub fn integers_greater_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 > integer2)
}

pub fn integers_less_than_or_equal_to(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 <= integer2)
}

pub fn integers_less_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 < integer2)
}

pub fn integers_not_equal(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 != integer2)
}

pub fn integers_prefix_greater_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.trim_start_matches(char::is_alphabetic);
    let integer2 = integer2.trim_start_matches(char::is_alphabetic);
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 > integer2)
}

pub fn integers_prefix_less_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.trim_start_matches(char::is_alphabetic);
    let integer2 = integer2.trim_start_matches(char::is_alphabetic);
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 < integer2)
}

type TestIoResult = Result<bool, io::Error>;

pub fn file_exists(file: &str) -> TestIoResult {
    _ = fs::metadata(file)?;
    Ok(true)
}

pub fn file_newer_than(file1: &str, file2: &str) -> TestIoResult {
    let file1_metadata = fs::metadata(file1)?;
    let file2_metadata = fs::metadata(file2)?;
    let file1_modified = file1_metadata.modified()?;
    let file2_modified = file2_metadata.modified()?;
    Ok(file1_modified > file2_modified)
}

pub fn file_older_than(file1: &str, file2: &str) -> TestIoResult {
    let file1_metadata = fs::metadata(file1)?;
    let file2_metadata = fs::metadata(file2)?;
    let file1_modified = file1_metadata.modified()?;
    let file2_modified = file2_metadata.modified()?;
    Ok(file1_modified < file2_modified)
}

pub fn file_exists_and_is_directory(file: &str) -> TestIoResult {
    let metadata = fs::metadata(file)?;
    Ok(metadata.is_dir())
}

pub fn file_exists_and_is_not_directory(file: &str) -> TestIoResult {
    let metadata = fs::metadata(file)?;
    Ok(!metadata.is_dir())
}

pub fn file_exists_and_size_greater_than_zero(file: &str) -> TestIoResult {
    let metadata = fs::metadata(file)?;
    Ok(metadata.len() > 0)
}

pub fn string_nonzero_length(string: &str) -> bool {
    !string.is_empty()
}

pub fn string_zero_length(string: &str) -> bool {
    string.is_empty()
}
