pub mod ollama;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionItem {
    pub text: String,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub done: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub summary: String,
    #[serde(default)]
    pub decisions: Vec<String>,
    #[serde(default)]
    pub action_items: Vec<ActionItem>,
}

impl Summary {
    /// Flattened text indexed for full-text search.
    pub fn searchable_text(&self) -> String {
        let mut parts = vec![self.summary.clone()];
        parts.extend(self.decisions.iter().cloned());
        parts.extend(self.action_items.iter().map(|a| a.text.clone()));
        parts.join("\n")
    }
}
