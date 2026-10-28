use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// Whisper model name, e.g. "base.en" -> ggml-base.en.bin
    pub whisper_model: String,
    /// ISO language code or "auto". Ignored (forced to "en") for `.en` models.
    pub language: String,
    pub ollama_url: String,
    pub ollama_model: String,
    pub capture_system_audio: bool,
    pub keep_audio: bool,
    pub auto_summarize: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            whisper_model: "base.en".into(),
            language: "en".into(),
            ollama_url: "http://127.0.0.1:11434".into(),
            ollama_model: "gemma4:12b".into(),
            capture_system_audio: true,
            keep_audio: false,
            auto_summarize: true,
        }
    }
}

impl Settings {
    pub fn effective_language(&self) -> Option<String> {
        if self.whisper_model.ends_with(".en") {
            Some("en".into())
        } else if self.language == "auto" || self.language.is_empty() {
            None
        } else {
            Some(self.language.clone())
        }
    }
}
