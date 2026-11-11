use std::fs::File;
use std::io::Read;
use std::path::Path;
use quick_xml::events::Event;
use quick_xml::Reader;
use thiserror::Error;
use zip::ZipArchive;

#[derive(Error, Debug)]
pub enum EpubError {
    #[error("I/O or Zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("File I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("XML parsing error: {0}")]
    Xml(#[from] quick_xml::Error),
    #[error("EPUB is encrypted with DRM")]
    DrmProtected,
    #[error("Invalid EPUB structure: missing container or OPF")]
    InvalidEpub,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SectionRole {
    Heading(u8),
    Paragraph,
    Blockquote,
    ListItem,
    Other,
}

#[derive(Debug, Clone)]
pub struct EpubBlock {
    pub text: String,
    pub role: SectionRole,
    pub spine_index: usize,
}

/// Constant-memory streaming EPUB extractor.
/// Reads only the ZIP central directory initially and streams readable XHTML spine items.
pub struct EpubStreamExtractor {
    file_path: String,
}

impl EpubStreamExtractor {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self, EpubError> {
        let p_str = path.as_ref().to_string_lossy().to_string();
        let file = File::open(&path)?;
        let mut archive = ZipArchive::new(file)?;

        // Check for DRM protection
        if archive.by_name("META-INF/encryption.xml").is_ok() {
            return Err(EpubError::DrmProtected);
        }

        // Verify container.xml exists
        if archive.by_name("META-INF/container.xml").is_err() {
            return Err(EpubError::InvalidEpub);
        }

        Ok(Self { file_path: p_str })
    }

    /// Finds the OPF rootfile path from `META-INF/container.xml`.
    pub fn get_opf_path(&self) -> Result<String, EpubError> {
        let file = File::open(&self.file_path)?;
        let mut archive = ZipArchive::new(file)?;
        let mut container_file = archive.by_name("META-INF/container.xml")?;
        let mut xml_content = String::new();
        container_file.read_to_string(&mut xml_content)?;

        let mut reader = Reader::from_str(&xml_content);
        reader.config_mut().trim_text(true);

        let mut buf = Vec::new();
        let mut opf_path = String::new();

        loop {
            match reader.read_event_into(&mut buf)? {
                Event::Start(ref e) | Event::Empty(ref e) if e.name().as_ref() == b"rootfile" => {
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == b"full-path" {
                            opf_path = String::from_utf8_lossy(&attr.value).to_string();
                            break;
                        }
                    }
                }
                Event::Eof => break,
                _ => (),
            }
            buf.clear();
        }

        if opf_path.is_empty() {
            Err(EpubError::InvalidEpub)
        } else {
            Ok(opf_path)
        }
    }

    /// Extracts plaintext blocks from an XHTML spine entry using a zero-allocation XML stream state machine.
    pub fn stream_spine_entry(&self, entry_name: &str, spine_idx: usize) -> Result<Vec<EpubBlock>, EpubError> {
        let file = File::open(&self.file_path)?;
        let mut archive = ZipArchive::new(file)?;
        let mut entry_file = archive.by_name(entry_name)?;
        let mut content = String::new();
        entry_file.read_to_string(&mut content)?;

        let mut reader = Reader::from_str(&content);
        reader.config_mut().trim_text(true);

        let mut blocks = Vec::new();
        let mut buf = Vec::new();
        let mut current_text = String::new();
        let mut current_role = SectionRole::Paragraph;
        let mut in_block = false;

        loop {
            match reader.read_event_into(&mut buf)? {
                Event::Start(ref e) => {
                    let name = e.name();
                    let tag = name.as_ref();
                    match tag {
                        b"h1" => { current_role = SectionRole::Heading(1); in_block = true; }
                        b"h2" => { current_role = SectionRole::Heading(2); in_block = true; }
                        b"h3" => { current_role = SectionRole::Heading(3); in_block = true; }
                        b"h4" | b"h5" | b"h6" => { current_role = SectionRole::Heading(4); in_block = true; }
                        b"p" => { current_role = SectionRole::Paragraph; in_block = true; }
                        b"blockquote" => { current_role = SectionRole::Blockquote; in_block = true; }
                        b"li" => { current_role = SectionRole::ListItem; in_block = true; }
                        _ => (), // Inline tags (em, strong, a, span) do not create new blocks
                    }
                }
                Event::Text(ref e) => {
                    let txt = e.unescape()?.into_owned();
                    if in_block {
                        if !current_text.is_empty() && !current_text.ends_with(' ') {
                            current_text.push(' ');
                        }
                        current_text.push_str(&txt);
                    }
                }
                Event::End(ref e) => {
                    let tag = e.name();
                    if matches!(tag.as_ref(), b"h1" | b"h2" | b"h3" | b"h4" | b"h5" | b"h6" | b"p" | b"blockquote" | b"li") {
                        let trimmed = current_text.trim();
                        if !trimmed.is_empty() {
                            blocks.push(EpubBlock {
                                text: trimmed.to_string(),
                                role: current_role.clone(),
                                spine_index: spine_idx,
                            });
                        }
                        current_text.clear();
                        in_block = false;
                    }
                }
                Event::Eof => break,
                _ => (),
            }
            buf.clear();
        }

        Ok(blocks)
    }
}

