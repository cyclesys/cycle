use std::path::Path;

use super::{Error, ReadState, Result};

pub struct StoredObject {
    // THe patch hash in which it was committed.
    pub hash: [u8; 32],
    // The index of the object when it was committed.
    pub idx: u64,
    // The hash of the definition that contains its type definition.
    pub def_hash: [u8; 32],
    // The index of the type that defines it.
    pub def_idx: u16,
    // The object's data.
    pub data: Box<[u8]>,
}

pub fn read_object_file(path: &Path, objects: &mut Vec<StoredObject>) -> Result<Box<[[u8; 32]]>> {
    let hash = {
        let file_name = path.file_name();
        let Some(file_name) = file_name else {
            return Err(Error::InvalidObjectFileName);
        };
        let Some(file_name) = file_name.to_str() else {
            return Err(Error::InvalidObjectFileName);
        };
        let Some(hash) = super::hash_hex_to_bytes(&file_name) else {
            return Err(Error::InvalidObjectFileName);
        };
        hash
    };
    // read the file and decompress the bytes
    let bytes = super::decode_file(path)?;
    let mut state = ReadState {
        bytes: bytes.as_slice(),
        cursor: 0,
    };

    let mut def_hashes = Vec::new();
    while !state.at_end() {
        let def_hash = {
            let mut def_hash = [0; 32];
            state.copy_bytes(&mut def_hash)?;
            def_hash
        };

        def_hashes.push(def_hash);

        let num_objects = state.read_u64()?;
        for _ in 0..num_objects {
            let def_idx = state.read_u16()?;
            let idx = state.read_u64()?;

            let data = {
                let data_size = state.read_u64()?;
                state.read_bytes(data_size as usize)?
            };

            objects.push(StoredObject {
                hash,
                idx,
                def_hash,
                def_idx,
                data: data.into_boxed_slice(),
            });
        }
    }

    Ok(def_hashes.into_boxed_slice())
}
