use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub enum SystemMessage {}

#[derive(Serialize, Deserialize)]
pub enum PluginMessage {}
