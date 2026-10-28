import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type Speaker = "Me" | "Them" | string;

export interface ActionItem {
  text: string;
  owner: string | null;
  done: boolean;
}

export interface Summary {
  summary: string;
  decisions: string[];
  actionItems: ActionItem[];
}

export interface Meeting {
  id: number;
  title: string;
  startedAt: string;
  endedAt: string | null;
  audioDir: string | null;
  summary: Summary | null;
  /** "none" | "running" | "done" | "error: …" */
  summaryStatus: string;
  segmentCount: number;
  durationMs: number;
}

export interface Segment {
  id: number;
  meetingId: number;
  speaker: Speaker;
  startMs: number;
  endMs: number;
  text: string;
}

export interface SearchHit {
  meetingId: number;
  meetingTitle: string;
  startedAt: string;
  kind: "transcript" | "summary";
  segmentId: number | null;
  speaker: string | null;
  startMs: number | null;
  /** Matches are wrapped in \u0001 … \u0002 */
  snippet: string;
}

export interface Settings {
  whisperModel: string;
  language: string;
  ollamaUrl: string;
  ollamaModel: string;
  captureSystemAudio: boolean;
  keepAudio: boolean;
  autoSummarize: boolean;
}

export interface ModelInfo {
  name: string;
  sizeMb: number;
  description: string;
  downloaded: boolean;
}

export interface OllamaStatus {
  running: boolean;
  models: string[];
  error: string | null;
}

export interface RecordingState {
  status: "idle" | "starting" | "recording" | "finishing";
  meetingId: number | null;
  startedAt: string | null;
}

export interface Levels {
  me: number;
  them: number;
}

export interface DownloadProgress {
  name: string;
  downloaded: number;
  total: number | null;
}

export const api = {
  getSettings: () => invoke<Settings>("get_settings"),
  saveSettings: (settings: Settings) => invoke<Settings>("save_settings", { settings }),
  listModels: () => invoke<ModelInfo[]>("list_models"),
  downloadModel: (name: string) => invoke<void>("download_model", { name }),
  ollamaStatus: () => invoke<OllamaStatus>("ollama_status"),
  openPrivacySettings: (pane: "microphone" | "screen") => invoke<void>("open_privacy_settings", { pane }),

  recordingState: () => invoke<RecordingState>("recording_state"),
  startMeeting: (title?: string) =>
    invoke<{ meeting: Meeting; warnings: string[] }>("start_meeting", { title: title || null }),
  stopMeeting: () => invoke<Meeting>("stop_meeting"),

  summarize: (id: number) => invoke<Summary>("summarize_meeting", { id }),
  toggleActionItem: (id: number, index: number) => invoke<Meeting>("toggle_action_item", { id, index }),

  listMeetings: () => invoke<Meeting[]>("list_meetings"),
  getMeeting: (id: number) => invoke<{ meeting: Meeting; segments: Segment[] }>("get_meeting", { id }),
  search: (query: string) => invoke<SearchHit[]>("search", { query }),
  renameMeeting: (id: number, title: string) => invoke<void>("rename_meeting", { id, title }),
  deleteMeeting: (id: number) => invoke<void>("delete_meeting", { id }),
  meetingMarkdown: (id: number) => invoke<string>("meeting_markdown", { id }),
  exportMarkdown: (id: number) => invoke<string>("export_markdown", { id }),
  revealAudio: (id: number) => invoke<void>("reveal_audio", { id }),
};

export const events = {
  segment: (cb: (s: Segment) => void): Promise<UnlistenFn> => listen<Segment>("segment", (e) => cb(e.payload)),
  levels: (cb: (l: Levels) => void) => listen<Levels>("levels", (e) => cb(e.payload)),
  recordingState: (cb: (s: RecordingState) => void) =>
    listen<RecordingState>("recording-state", (e) => cb(e.payload)),
  summaryStatus: (cb: (s: { meetingId: number; status: string }) => void) =>
    listen<{ meetingId: number; status: string }>("summary-status", (e) => cb(e.payload)),
  modelDownload: (cb: (p: DownloadProgress) => void) =>
    listen<DownloadProgress>("model-download", (e) => cb(e.payload)),
};

/** Subscribes in an effect and cleans up correctly even if unmounted before `listen` resolves. */
export function subscribe(p: Promise<UnlistenFn>): () => void {
  let unlisten: UnlistenFn | null = null;
  let cancelled = false;
  p.then((fn) => (cancelled ? fn() : (unlisten = fn)));
  return () => {
    cancelled = true;
    unlisten?.();
  };
}

export function errorMessage(e: unknown): string {
  return typeof e === "string" ? e : e instanceof Error ? e.message : JSON.stringify(e);
}
