mod audio;
mod commands;
mod db;
mod export;
mod llm;
#[cfg(test)]
mod pipeline_tests;
mod recorder;
mod settings;
mod transcribe;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir)?;
            let db = db::Db::open(&data_dir.join("meetings.sqlite"))?;
            app.manage(commands::AppState::new(db, data_dir));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::list_models,
            commands::download_model,
            commands::ollama_status,
            commands::open_privacy_settings,
            commands::recording_state,
            commands::start_meeting,
            commands::stop_meeting,
            commands::summarize_meeting,
            commands::toggle_action_item,
            commands::list_meetings,
            commands::get_meeting,
            commands::search,
            commands::rename_meeting,
            commands::delete_meeting,
            commands::meeting_markdown,
            commands::export_markdown,
            commands::reveal_audio,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
