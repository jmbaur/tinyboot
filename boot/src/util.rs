use std::fs;

fn exit_code_from(result: bool) -> u8 {
    match result {
        false => 1,
        true => 0,
    }
}

pub fn strings_equal(string1: &str, string2: &str) -> u8 {
    exit_code_from(string1 == string2)
}

pub fn strings_not_equal(string1: &str, string2: &str) -> u8 {
    exit_code_from(string1 != string2)
}

pub fn strings_lexographically_less_than(string1: &str, string2: &str) -> u8 {
    exit_code_from(string1 < string2)
}

pub fn strings_lexographically_less_than_or_equal_to(string1: &str, string2: &str) -> u8 {
    exit_code_from(string1 <= string2)
}

pub fn strings_lexographically_greater_than(string1: &str, string2: &str) -> u8 {
    exit_code_from(string1 > string2)
}

pub fn strings_lexographically_greater_than_or_equal_to(string1: &str, string2: &str) -> u8 {
    exit_code_from(string1 >= string2)
}

pub fn integers_equal(integer1: &str, integer2: &str) -> u8 {
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 == integer2)
}

pub fn integers_greater_than_or_equal_to(integer1: &str, integer2: &str) -> u8 {
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 >= integer2)
}

pub fn integers_greater_than(integer1: &str, integer2: &str) -> u8 {
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 > integer2)
}

pub fn integers_less_than_or_equal_to(integer1: &str, integer2: &str) -> u8 {
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 <= integer2)
}

pub fn integers_less_than(integer1: &str, integer2: &str) -> u8 {
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 < integer2)
}

pub fn integers_not_equal(integer1: &str, integer2: &str) -> u8 {
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 != integer2)
}

pub fn integers_prefix_greater_than(integer1: &str, integer2: &str) -> u8 {
    let integer1 = integer1.trim_start_matches(char::is_alphabetic);
    let integer2 = integer2.trim_start_matches(char::is_alphabetic);
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 > integer2)
}

pub fn integers_prefix_less_than(integer1: &str, integer2: &str) -> u8 {
    let integer1 = integer1.trim_start_matches(char::is_alphabetic);
    let integer2 = integer2.trim_start_matches(char::is_alphabetic);
    let Ok(integer1) = integer1.parse::<i64>() else { return 1; };
    let Ok(integer2) = integer2.parse::<i64>() else { return 1; };
    exit_code_from(integer1 < integer2)
}

pub fn file_exists(file: &str) -> u8 {
    exit_code_from(fs::metadata(file).is_ok())
}

pub fn file_newer_than(file1: &str, file2: &str) -> u8 {
    let Ok(file1_metadata) = fs::metadata(file1) else { return 1; };
    let Ok(file2_metadata) = fs::metadata(file2) else { return 1; };
    let Ok(file1_modified) = file1_metadata.modified() else { return 1; };
    let Ok(file2_modified) = file2_metadata.modified() else { return 1; };
    exit_code_from(file1_modified > file2_modified)
}

pub fn file_older_than(file1: &str, file2: &str) -> u8 {
    let Ok(file1_metadata) = fs::metadata(file1) else { return 1; };
    let Ok(file2_metadata) = fs::metadata(file2) else { return 1; };
    let Ok(file1_modified) = file1_metadata.modified() else { return 1; };
    let Ok(file2_modified) = file2_metadata.modified() else { return 1; };
    exit_code_from(file1_modified < file2_modified)
}

pub fn file_exists_and_is_directory(file: &str) -> u8 {
    let Ok(metadata) = fs::metadata(file) else {
        return exit_code_from(false);
    };
    exit_code_from(metadata.is_dir())
}

pub fn file_exists_and_is_not_directory(file: &str) -> u8 {
    let Ok(metadata) = fs::metadata(file) else {
        return exit_code_from(false);
    };
    exit_code_from(!metadata.is_dir())
}

pub fn file_exists_and_size_greater_than_zero(file: &str) -> u8 {
    let Ok(metadata) = fs::metadata(file) else {
        return exit_code_from(false);
    };
    exit_code_from(metadata.len() > 0)
}

pub fn string_nonzero_length(string: &str) -> u8 {
    exit_code_from(!string.is_empty())
}

pub fn string_zero_length(string: &str) -> u8 {
    exit_code_from(string.is_empty())
}
