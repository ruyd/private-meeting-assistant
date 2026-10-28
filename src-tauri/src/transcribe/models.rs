//! Whisper model catalogue and one-time download from Hugging Face.
//! This download is the only network access the app makes besides the
//! local Ollama server.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use futures_util::StreamExt;
use serde::Serialize;
use tokio::io::AsyncWriteExt;

const BASE_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub name: &'static str,
    pub size_mb: u32,
    pub description: &'static str,
    pub downloaded: bool,
}

const CATALOGUE: &[(&str, u32, &str)] = &[
    ("tiny.en", 75, "Fastest, English only, lower accuracy"),
    ("base.en", 142, "Fast, English only — good default"),
    ("small.en", 466, "More accurate, English only"),
    ("small", 466, "More accurate, multilingual"),
    ("large-v3-turbo-q5_0", 547, "Best accuracy, multilingual (Apple Silicon recommended)"),
];

pub fn models_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("models")
}

pub fn model_path(data_dir: &Path, name: &str) -> PathBuf {
    models_dir(data_dir).join(format!("ggml-{name}.bin"))
}

pub fn list(data_dir: &Path) -> Vec<ModelInfo> {
    CATALOGUE
        .iter()
        .map(|&(name, size_mb, description)| ModelInfo {
            name,
            size_mb,
            description,
            downloaded: model_path(data_dir, name).exists(),
        })
        .collect()
}

/// Downloads to a temp file and renames on success so a half-finished
/// download is never mistaken for a model.
pub async fn download(
    data_dir: &Path,
    name: &str,
    mut on_progress: impl FnMut(u64, Option<u64>),
) -> Result<PathBuf> {
    if !CATALOGUE.iter().any(|(n, _, _)| *n == name) {
        bail!("unknown model {name}");
    }
    let dest = model_path(data_dir, name);
    tokio::fs::create_dir_all(models_dir(data_dir)).await?;
    let tmp = dest.with_extension("part");

    let resp = reqwest::get(format!("{BASE_URL}/ggml-{name}.bin"))
        .await?
        .error_for_status()
        .context("downloading model")?;
    let total = resp.content_length();
    let mut file = tokio::fs::File::create(&tmp).await?;
    let mut done = 0u64;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        done += chunk.len() as u64;
        on_progress(done, total);
    }
    file.flush().await?;
    drop(file);
    tokio::fs::rename(&tmp, &dest).await?;
    Ok(dest)
}
