import { createContext, useContext, useEffect, useState } from "react";
import { NavLink, Route, Routes } from "react-router-dom";
import { api, events, subscribe, type RecordingState } from "./lib/api";
import Live from "./pages/Live";
import Meetings from "./pages/Meetings";
import MeetingPage from "./pages/Meeting";
import SettingsPage from "./pages/Settings";

const idle: RecordingState = { status: "idle", meetingId: null, startedAt: null };
const RecordingContext = createContext<RecordingState>(idle);
export const useRecording = () => useContext(RecordingContext);

export default function App() {
  const [recording, setRecording] = useState<RecordingState>(idle);

  useEffect(() => {
    api.recordingState().then(setRecording);
    return subscribe(events.recordingState(setRecording));
  }, []);

  const live = recording.status === "recording" || recording.status === "finishing";

  return (
    <RecordingContext.Provider value={recording}>
      <div className="flex h-full">
        <nav className="flex w-52 shrink-0 flex-col gap-0.5 border-r border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-950">
          <div className="mb-4 px-2 pt-1">
            <div className="text-sm font-semibold">Meeting Assistant</div>
            <div className="text-xs text-zinc-500">Private · on-device</div>
          </div>
          <Item to="/" label="Record" badge={live} />
          <Item to="/meetings" label="Meetings" />
          <div className="flex-1" />
          <Item to="/settings" label="Settings" />
        </nav>
        <main className="min-w-0 flex-1 overflow-y-auto">
          <Routes>
            <Route path="/" element={<Live />} />
            <Route path="/meetings" element={<Meetings />} />
            <Route path="/meetings/:id" element={<MeetingPage />} />
            <Route path="/settings" element={<SettingsPage />} />
          </Routes>
        </main>
      </div>
    </RecordingContext.Provider>
  );
}

function Item({ to, label, badge }: { to: string; label: string; badge?: boolean }) {
  return (
    <NavLink
      to={to}
      end={to === "/"}
      className={({ isActive }) =>
        `flex items-center justify-between rounded-md px-2 py-1.5 text-sm ${
          isActive
            ? "bg-zinc-200/80 font-medium dark:bg-zinc-800"
            : "text-zinc-600 hover:bg-zinc-200/50 dark:text-zinc-400 dark:hover:bg-zinc-800/60"
        }`
      }
    >
      {label}
      {badge && <span className="h-2 w-2 animate-pulse rounded-full bg-red-500" aria-label="recording" />}
    </NavLink>
  );
}
