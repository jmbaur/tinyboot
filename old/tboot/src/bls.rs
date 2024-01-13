use std::fmt::Display;

#[derive(Debug, PartialEq)]
pub enum BlsEntryError {
    MissingConfSuffix,
    InvalidTriesSyntax,
    MissingFileName,
}

impl Display for BlsEntryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

pub type BlsEntryMetadata = (String, Option<u32>, Option<u32>);

/// Parses an entry filename and returns a tuple of the form (entry name, tries done, tries left).
/// It follows the convention layed out the boot counter section of the BootLoaderSpec.
/// https://uapi-group.org/specifications/specs/boot_loader_specification/#boot-counting
pub fn parse_entry_filename(filename: &str) -> Result<BlsEntryMetadata, BlsEntryError> {
    let filename = filename
        .strip_suffix(".conf")
        .ok_or(BlsEntryError::MissingConfSuffix)?;

    match filename.split_once('+') {
        None => Ok((filename.to_string(), None, None)),
        Some((name, counter_info)) => match counter_info.split_once('-') {
            None => {
                let tries_done = u32::from_str_radix(counter_info, 10)
                    .map_err(|_| BlsEntryError::InvalidTriesSyntax)?;
                return Ok((name.to_string(), Some(tries_done), None));
            }
            Some((tries_done, tries_left)) => {
                let tries_done = u32::from_str_radix(tries_done, 10)
                    .map_err(|_| BlsEntryError::InvalidTriesSyntax)?;
                let tries_left = u32::from_str_radix(tries_left, 10)
                    .map_err(|_| BlsEntryError::InvalidTriesSyntax)?;
                return Ok((name.to_string(), Some(tries_done), Some(tries_left)));
            }
        },
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn test_parse_entry_filename() {
        // error cases
        assert_eq!(
            super::parse_entry_filename("my-entry"),
            Err(super::BlsEntryError::MissingConfSuffix)
        );
        assert_eq!(
            super::parse_entry_filename("my-entry+foo.conf"),
            Err(super::BlsEntryError::InvalidTriesSyntax)
        );
        assert_eq!(
            super::parse_entry_filename("my-entry+foo-bar.conf"),
            Err(super::BlsEntryError::InvalidTriesSyntax)
        );

        // happy path
        assert_eq!(
            super::parse_entry_filename("my-entry.conf"),
            Ok(("my-entry".to_string(), None, None))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry+1.conf"),
            Ok(("my-entry".to_string(), Some(1), None))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry+0.conf"),
            Ok(("my-entry".to_string(), Some(0), None))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry-1.conf"),
            Ok(("my-entry-1".to_string(), None, None))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry+0-3.conf"),
            Ok(("my-entry".to_string(), Some(0), Some(3)))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry-1+5-0.conf"),
            Ok(("my-entry-1".to_string(), Some(5), Some(0)))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry-2+3-1.conf"),
            Ok(("my-entry-2".to_string(), Some(3), Some(1)))
        );
        assert_eq!(
            super::parse_entry_filename("my-entry-3+2.conf"),
            Ok(("my-entry-3".to_string(), Some(2), None))
        );
    }
}
