use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::db::{Db, Meeting, SearchHit, Segment};
use crate::llm::{ollama, Summary};
use crate::recorder::{self, Session, StartOptions};
use crate::settings::Settings;
use crate::transcribe::models::{self, ModelInfo};
use crate::transcribe::whisper::Transcriber;
use crate::export;

type CmdResult<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn anyhow_err(e: anyhow::Error) -> String {
    format!("{e:#}")
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingState {
    /// "idle" | "starting" | "recording" | "finishing"
    pub status: String,
    pub meeting_id: Option<i64>,
    pub started_at: Option<String>,
}

pub struct AppState {
    pub db: Db,
    pub data_dir: PathBuf,
    session: Mutex<Option<Session>>,
    transcriber: Mutex<Option<(String, Arc<Transcriber>)>>,
    recording: Mutex<RecordingState>,
}

impl AppState {
    pub fn new(db: Db, data_dir: PathBuf) -> Self {
        Self {
            db,
            data_dir,
            session: Mutex::new(None),
            transcriber: Mutex::new(None),
            recording: Mutex::new(RecordingState { status: "idle".into(), ..Default::default() }),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn set_recording(app: &AppHandle, st: RecordingState) {
    let state = app.state::<AppState>();
    *lock(&state.recording) = st.clone();
    let _ = app.emit("recording-state", st);
}

// --- settings & setup ---------------------------------------------------

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> CmdResult<Settings> {
    state.db.settings().map_err(anyhow_err)
}

#[tauri::command]
pub fn save_settings(state: State<'_, AppState>, settings: Settings) -> CmdResult<Settings> {
    state.db.save_settings(&settings).map_err(anyhow_err)?;
    Ok(settings)
}

#[tauri::command]
pub fn list_models(state: State<'_, AppState>) -> Vec<ModelInfo> {
    models::list(&state.data_dir)
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadProgress {
    name: String,
    downloaded: u64,
    total: Option<u64>,
}

#[tauri::command]
pub async fn download_model(app: AppHandle, name: String) -> CmdResult<()> {
    let data_dir = app.state::<AppState>().data_dir.clone();
    let mut last_emit = 0u64;
    models::download(&data_dir, &name, |downloaded, total| {
        // Emit roughly every 2 MB to keep the event stream light.
        if downloaded - last_emit >= 2 << 20 || Some(downloaded) == total {
            last_emit = downloaded;
            let _ = app.emit(
                "model-download",
                DownloadProgress { name: name.clone(), downloaded, total },
            );
        }
    })
    .await
    .map_err(anyhow_err)?;
    Ok(())
}

#[tauri::command]
pub async fn ollama_status(state: State<'_, AppState>) -> CmdResult<ollama::OllamaStatus> {
    let url = state.db.settings().map_err(anyhow_err)?.ollama_url;
    Ok(ollama::status(&url).await)
}

#[tauri::command]
pub fn open_privacy_settings(pane: String) -> CmdResult<()> {
    let anchor = match pane.as_str() {
        "microphone" => "Privacy_Microphone",
        "screen" => "Privacy_ScreenCapture",
        _ => return Err(format!("unknown pane {pane}")),
    };
    std::process::Command::new("open")
        .arg(format!("x-apple.systempreferences:com.apple.preference.security?{anchor}"))
        .spawn()
        .map_err(err)?;
    Ok(())
}

// --- recording ----------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartResult {
    meeting: Meeting,
    warnings: Vec<String>,
}

#[tauri::command]
pub fn recording_state(state: State<'_, AppState>) -> RecordingState {
    lock(&state.recording).clone()
}

#[tauri::command]
pub async fn start_meeting(app: AppHandle, title: Option<String>) -> CmdResult<StartResult> {
    {
        let state = app.state::<AppState>();
        let mut rec = lock(&state.recording);
        if rec.status != "idle" {
            return Err("A recording is already in progress".into());
        }
        rec.status = "starting".into();
    }
    let _ = app.emit("recording-state", recording_state(app.state()));

    let app2 = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || start_blocking(&app2, title))
        .await
        .map_err(err)
        .and_then(|r| r);
    if result.is_err() {
        set_recording(&app, RecordingState { status: "idle".into(), ..Default::default() });
    }
    result
}

fn start_blocking(app: &AppHandle, title: Option<String>) -> CmdResult<StartResult> {
    let state = app.state::<AppState>();
    let settings = state.db.settings().map_err(anyhow_err)?;

    let model_path = models::model_path(&state.data_dir, &settings.whisper_model);
    if !model_path.exists() {
        return Err(format!(
            "The Whisper model \"{}\" isn't downloaded yet. Download it in Settings.",
            settings.whisper_model
        ));
    }
    let transcriber = {
        let mut cached = lock(&state.transcriber);
        match cached.as_ref() {
            Some((name, t)) if *name == settings.whisper_model => t.clone(),
            _ => {
                *cached = None; // free the old model before loading another
                let t = Arc::new(Transcriber::load(&model_path).map_err(anyhow_err)?);
                *cached = Some((settings.whisper_model.clone(), t.clone()));
                t
            }
        }
    };

    let now = chrono::Utc::now();
    let title = title
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| format!("Meeting {}", now.with_timezone(&chrono::Local).format("%b %-d, %H:%M")));
    let started_at = now.to_rfc3339();
    let id = state.db.create_meeting(&title, &started_at).map_err(anyhow_err)?;

    let audio_dir = settings.keep_audio.then(|| state.data_dir.join("audio").join(id.to_string()));
    if let Some(dir) = &audio_dir {
        state.db.set_audio_dir(id, &dir.to_string_lossy()).map_err(anyhow_err)?;
    }

    let opts = StartOptions {
        meeting_id: id,
        capture_system_audio: settings.capture_system_audio,
        language: settings.effective_language(),
        audio_dir,
    };
    let (session, warnings) = match recorder::start(app.clone(), state.db.clone(), transcriber, opts) {
        Ok(r) => r,
        Err(e) => {
            let _ = state.db.delete_meeting(id);
            return Err(anyhow_err(e));
        }
    };
    *lock(&state.session) = Some(session);
    set_recording(
        app,
        RecordingState { status: "recording".into(), meeting_id: Some(id), started_at: Some(started_at) },
    );

    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting vanished")?;
    Ok(StartResult { meeting, warnings })
}

#[tauri::command]
pub async fn stop_meeting(app: AppHandle) -> CmdResult<Meeting> {
    let state = app.state::<AppState>();
    let session = lock(&state.session).take().ok_or("Nothing is recording")?;
    let id = session.meeting_id;
    let started_at = lock(&state.recording).started_at.clone();
    set_recording(
        &app,
        RecordingState { status: "finishing".into(), meeting_id: Some(id), started_at },
    );

    tauri::async_runtime::spawn_blocking(move || session.finish())
        .await
        .map_err(err)?;

    state.db.end_meeting(id, &chrono::Utc::now().to_rfc3339()).map_err(anyhow_err)?;
    set_recording(&app, RecordingState { status: "idle".into(), ..Default::default() });

    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting vanished")?;
    let settings = state.db.settings().map_err(anyhow_err)?;
    if settings.auto_summarize && meeting.segment_count > 0 {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let _ = run_summary(&app, id).await;
        });
    }
    Ok(meeting)
}

// --- summaries ----------------------------------------------------------

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SummaryStatus {
    meeting_id: i64,
    status: String,
}

async fn run_summary(app: &AppHandle, id: i64) -> CmdResult<Summary> {
    let state = app.state::<AppState>();
    let db = state.db.clone();
    let emit = |status: &str| {
        let _ = db.set_summary_status(id, status);
        let _ = app.emit("summary-status", SummaryStatus { meeting_id: id, status: status.into() });
    };

    emit("running");
    let result = async {
        let settings = db.settings()?;
        let segments = db.segments(id)?;
        let summary = ollama::summarize(&settings.ollama_url, &settings.ollama_model, &segments).await?;
        db.save_summary(id, &summary)?;
        anyhow::Ok(summary)
    }
    .await;

    match result {
        Ok(s) => {
            emit("done");
            Ok(s)
        }
        Err(e) => {
            let msg = format!("error: {e:#}");
            emit(&msg);
            Err(msg)
        }
    }
}

#[tauri::command]
pub async fn summarize_meeting(app: AppHandle, id: i64) -> CmdResult<Summary> {
    run_summary(&app, id).await
}

#[tauri::command]
pub fn toggle_action_item(state: State<'_, AppState>, id: i64, index: usize) -> CmdResult<Meeting> {
    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting not found")?;
    let mut summary = meeting.summary.ok_or("meeting has no summary")?;
    let item = summary.action_items.get_mut(index).ok_or("no such action item")?;
    item.done = !item.done;
    state.db.save_summary(id, &summary).map_err(anyhow_err)?;
    state.db.get_meeting(id).map_err(anyhow_err)?.ok_or_else(|| "meeting not found".into())
}

// --- archive ------------------------------------------------------------

#[tauri::command]
pub fn list_meetings(state: State<'_, AppState>) -> CmdResult<Vec<Meeting>> {
    state.db.list_meetings().map_err(anyhow_err)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingDetail {
    meeting: Meeting,
    segments: Vec<Segment>,
}

#[tauri::command]
pub fn get_meeting(state: State<'_, AppState>, id: i64) -> CmdResult<MeetingDetail> {
    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting not found")?;
    let segments = state.db.segments(id).map_err(anyhow_err)?;
    Ok(MeetingDetail { meeting, segments })
}

#[tauri::command]
pub fn search(state: State<'_, AppState>, query: String) -> CmdResult<Vec<SearchHit>> {
    state.db.search(&query).map_err(anyhow_err)
}

#[tauri::command]
pub fn rename_meeting(state: State<'_, AppState>, id: i64, title: String) -> CmdResult<()> {
    let title = title.trim();
    if title.is_empty() {
        return Err("Title can't be empty".into());
    }
    state.db.rename_meeting(id, title).map_err(anyhow_err)
}

#[tauri::command]
pub fn delete_meeting(state: State<'_, AppState>, id: i64) -> CmdResult<()> {
    if lock(&state.recording).meeting_id == Some(id) {
        return Err("Stop the recording before deleting it".into());
    }
    if let Some(dir) = state.db.delete_meeting(id).map_err(anyhow_err)? {
        // Only ever remove folders inside our own audio directory.
        let dir = PathBuf::from(dir);
        if dir.starts_with(state.data_dir.join("audio")) {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
    Ok(())
}

#[tauri::command]
pub fn meeting_markdown(state: State<'_, AppState>, id: i64) -> CmdResult<String> {
    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting not found")?;
    let segments = state.db.segments(id).map_err(anyhow_err)?;
    Ok(export::to_markdown(&meeting, &segments))
}

/// Saves the meeting as Markdown in ~/Downloads and reveals it in Finder.
#[tauri::command]
pub fn export_markdown(app: AppHandle, id: i64) -> CmdResult<String> {
    let state = app.state::<AppState>();
    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting not found")?;
    let segments = state.db.segments(id).map_err(anyhow_err)?;
    let dir = app.path().download_dir().map_err(err)?;
    let mut path = dir.join(format!("{}.md", export::file_name(&meeting.title)));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{} ({n}).md", export::file_name(&meeting.title)));
        n += 1;
    }
    std::fs::write(&path, export::to_markdown(&meeting, &segments)).map_err(err)?;
    let _ = std::process::Command::new("open").arg("-R").arg(&path).spawn();
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn reveal_audio(state: State<'_, AppState>, id: i64) -> CmdResult<()> {
    let meeting = state.db.get_meeting(id).map_err(anyhow_err)?.ok_or("meeting not found")?;
    let dir = meeting.audio_dir.ok_or("No audio was kept for this meeting")?;
    std::process::Command::new("open").arg(dir).spawn().map_err(err)?;
    Ok(())
}
