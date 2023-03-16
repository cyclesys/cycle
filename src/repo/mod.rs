use flate2::{
    write::{ZlibDecoder, ZlibEncoder},
    Compression,
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};
use url::Url;

mod definition;
use definition::StoredDefinition;

mod object;
use object::StoredObject;

pub enum Error {
    InvalidPath,
    InvalidDir {
        has_leaves_file: bool,
        has_patches_dir: bool,
        has_objects_dir: bool,
        has_definitions_dir: bool,
    },
    InvalidObjectFileName,
    InvalidObjectFile,
    CorruptFile,
    IO(io::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

fn result_from_io<T>(result: io::Result<T>) -> Result<T> {
    match result {
        Ok(result) => Ok(result),
        Err(err) => Err(Error::IO(err)),
    }
}

pub struct SourceRepo {
    // Objects found in the 'objects' sub-folder.
    objects: Vec<StoredObject>,
    // Definitions found in the 'definitions' sub-folder, and only those that define the currently
    // active objects.
    definitions: Vec<StoredDefinition>,
}

impl SourceRepo {
    pub fn open(repo_url: Url) -> Result<Self> {
        if repo_url.scheme() != "repo" {
            return Err(Error::InvalidPath);
        }

        let repo_path = Path::new(repo_url.path());
        if !repo_path.is_dir() {
            return Err(Error::InvalidPath);
        }

        // ensure that this is a valid repo directory
        {
            let mut has_leaves_file = false;
            let mut has_patches_dir = false;
            let mut has_objects_dir = false;
            let mut has_definitions_dir = false;

            let dir = result_from_io(fs::read_dir(&repo_path))?;
            for entry in dir {
                let entry = result_from_io(entry)?;
                let entry_type = result_from_io(entry.file_type())?;

                if entry_type.is_file() {
                    if let Some(file_stem) = entry.path().file_stem() {
                        match file_stem.to_str().unwrap() {
                            "leaves" => {
                                has_leaves_file = true;
                            }
                            _ => {}
                        }
                    }
                } else if entry_type.is_dir() {
                    if let Some(file_name) = entry.path().file_name() {
                        match file_name.to_str().unwrap() {
                            "patches" => {
                                has_patches_dir = true;
                            }
                            "objects" => {
                                has_objects_dir = true;
                            }
                            "definitions" => {
                                has_definitions_dir = true;
                            }
                            _ => {}
                        }
                    }
                }
            }

            if !has_leaves_file || !has_patches_dir || !has_objects_dir || !has_definitions_dir {
                return Err(Error::InvalidDir {
                    has_leaves_file,
                    has_patches_dir,
                    has_objects_dir,
                    has_definitions_dir,
                });
            }
        }

        let mut objects = Vec::new();
        // for some reason it can't infer the element type here
        let mut definitions = Vec::<StoredDefinition>::new();
        {
            let mut dir_path = PathBuf::from(repo_path);
            dir_path.push("objects/");

            let dir = result_from_io(fs::read_dir(dir_path))?;
            for entry in dir {
                let entry = result_from_io(entry)?;
                let entry_type = result_from_io(entry.file_type())?;

                if !entry_type.is_file() {
                    continue;
                }

                let def_hashes = object::read_object_file(&entry.path(), &mut objects)?;

                // read the new definition files
                for def_hash in def_hashes.as_ref() {
                    let mut definition_already_read = false;
                    for def in &definitions {
                        if *def_hash == def.hash {
                            definition_already_read = true;
                            break;
                        }
                    }
                    if !definition_already_read {
                        let mut def_file_path = entry.path();
                        def_file_path.pop();
                        def_file_path.pop();
                        def_file_path.push("definitions/");

                        let def_file_name = hash_bytes_to_hex(&def_hash);
                        def_file_path.push(def_file_name);

                        definition::read_definition_file(
                            &def_file_path,
                            *def_hash,
                            &mut definitions,
                        )?;
                    }
                }
            }
        }

        Ok(Self {
            objects,
            definitions,
        })
    }
}

pub struct ReadState<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> ReadState<'a> {
    pub fn copy_bytes(&mut self, buf: &mut [u8]) -> Result<()> {
        self.ensure_can_read(buf.len())?;
        buf.copy_from_slice(&self.bytes[self.cursor..(self.cursor + buf.len())]);
        self.cursor += buf.len();
        Ok(())
    }

    pub fn read_bytes(&mut self, size: usize) -> Result<Vec<u8>> {
        self.ensure_can_read(size)?;
        let mut buf = Vec::with_capacity(size);
        for i in self.cursor..(self.cursor + size) {
            buf.push(self.bytes[i]);
        }
        self.cursor += size;
        Ok(buf)
    }

    pub fn read_u8(&mut self) -> Result<u8> {
        self.ensure_can_read(1)?;
        let v = self.bytes[self.cursor];
        self.cursor += 1;
        Ok(v)
    }

    pub fn read_u16(&mut self) -> Result<u16> {
        self.ensure_can_read(2)?;
        let mut buf = [0; 2];
        self.copy_bytes(&mut buf);
        Ok(u16::from_le_bytes(buf))
    }

    pub fn read_u32(&mut self) -> Result<u32> {
        self.ensure_can_read(4)?;
        let mut buf = [0; 4];
        self.copy_bytes(&mut buf);
        Ok(u32::from_le_bytes(buf))
    }

    pub fn read_u64(&mut self) -> Result<u64> {
        self.ensure_can_read(8)?;
        let mut buf = [0; 8];
        self.copy_bytes(&mut buf);
        Ok(u64::from_le_bytes(buf))
    }

    pub fn read_string(&mut self) -> Result<String> {
        let mut string_size = self.read_u16()?;
        let string = self.read_bytes(string_size as usize)?;

        match String::from_utf8(string) {
            Ok(string) => Ok(string),
            Err(_) => Err(Error::CorruptFile),
        }
    }

    pub fn at_end(&self) -> bool {
        self.cursor >= self.bytes.len()
    }

    fn ensure_can_read(&self, len: usize) -> Result<()> {
        if self.cursor + len > self.bytes.len() {
            Err(Error::CorruptFile)
        } else {
            Ok(())
        }
    }
}

pub fn decode_file(path: &Path) -> Result<Vec<u8>> {
    let bytes = result_from_io(fs::read(path))?;
    let mut decoder = ZlibDecoder::new(Vec::new());
    result_from_io(decoder.write_all(&bytes))?;
    result_from_io(decoder.finish())
}

// TODO: move to util file?
pub fn hash_bytes_to_hex(bytes: &[u8; 32]) -> String {
    let mut hex = String::with_capacity(bytes.len() * 2);
    let mut push = |byte| {
        hex.push(char::from_digit(byte as u32, 16).unwrap());
    };
    for byte in bytes {
        push((*byte & 0b11110000) >> 4);
        push(*byte & 0b00001111);
    }
    hex
}

// TODO: move to util file?
pub fn hash_hex_to_bytes(hex: &str) -> Option<[u8; 32]> {
    fn match_hex_to_byte(hex_byte: u8) -> Option<u8> {
        match hex_byte {
            b'0'..=b'9' => Some(hex_byte - 48),
            b'A'..=b'Z' => Some(hex_byte - 55),
            b'a'..=b'z' => Some(hex_byte - 87),
            _ => None,
        }
    }

    let mut bytes = [0; 32];
    let hex_bytes = hex.as_bytes();

    for i in 0..bytes.len() {
        let hex_i = i * 2;
        let Some(most) = match_hex_to_byte(hex_bytes[hex_i]) else {
            return None;
        };
        let Some(least) = match_hex_to_byte(hex_bytes[hex_i + 1]) else {
            return None;
        };
        bytes[i] = (most << 4) | least;
    }
    Some(bytes)
}
