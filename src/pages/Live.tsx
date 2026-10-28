import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useRecording } from "../App";
import { ErrorBox, LevelMeter, Notice, Spinner, Transcript } from "../components";
import { api, errorMessage, events, subscribe, type Levels, type Segment } from "../lib/api";
import { timestamp } from "../lib/format";

export default function Live() {
  const rec = useRecording();
  const navigate = useNavigate();
  const [title, setTitle] = useState("");
  const [segments, setSegments] = useState<Segment[]>([]);
  const [levels, setLevels] = useState<Levels>({ me: 0, them: 0 });
  const [warnings, setWarnings] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [modelMissing, setModelMissing] = useState(false);

  const active = rec.status === "recording" || rec.status === "finishing";

  // Pick up a meeting already in progress (e.g. after navigating away and back).
  useEffect(() => {
    if (rec.meetingId == null) return;
    api.getMeeting(rec.meetingId).then(({ meeting, segments }) => {
      setTitle(meeting.title);
      setSegments(segments);
    });
  }, [rec.meetingId]);

  useEffect(() => {
    return subscribe(
      events.segment((s) =>
        setSegments((prev) =>
          prev.some((p) => p.id === s.id) ? prev : [...prev, s].sort((a, b) => a.startMs - b.startMs || a.id - b.id),
        ),
      ),
    );
  }, []);

  useEffect(() => subscribe(events.levels(setLevels)), []);

  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(t);
  }, [active]);

  useEffect(() => {
    Promise.all([api.getSettings(), api.listModels()]).then(([s, models]) =>
      setModelMissing(!models.find((m) => m.name === s.whisperModel)?.downloaded),
    );
  }, []);

  async function start() {
    setError(null);
    setWarnings([]);
    setSegments([]);
    try {
      const { meeting, warnings } = await api.startMeeting(title);
      setTitle(meeting.title);
      setWarnings(warnings);
    } catch (e) {
      setError(errorMessage(e));
    }
  }

  async function stop() {
    setError(null);
    try {
      const meeting = await api.stopMeeting();
      setTitle("");
      setSegments([]);
      navigate(`/meetings/${meeting.id}`);
    } catch (e) {
      setError(errorMessage(e));
    }
  }

  const elapsed = rec.startedAt ? now - new Date(rec.startedAt).getTime() : 0;

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-5 p-8">
      <header className="flex items-center gap-3">
        {active ? (
          <h1 className="min-w-0 flex-1 truncate text-xl font-semibold">{title}</h1>
        ) : (
          <input
            className="input flex-1 text-base"
            placeholder="Meeting title (optional)"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && start()}
          />
        )}
        {rec.status === "idle" && (
          <button className="btn-primary" onClick={start} disabled={modelMissing}>
            <span className="h-2.5 w-2.5 rounded-full bg-red-400" /> Start recording
          </button>
        )}
        {rec.status === "starting" && (
          <button className="btn" disabled>
            <Spinner /> Loading model…
          </button>
        )}
        {rec.status === "recording" && (
          <button className="btn" onClick={stop}>
            <span className="h-2.5 w-2.5 rounded-sm bg-red-500" /> Stop
          </button>
        )}
        {rec.status === "finishing" && (
          <button className="btn" disabled>
            <Spinner /> Finishing transcript…
          </button>
        )}
      </header>

      {modelMissing && rec.status === "idle" && (
        <Notice>
          No speech model downloaded yet.{" "}
          <Link to="/settings" className="font-medium underline">
            Download one in Settings
          </Link>{" "}
          to start transcribing.
        </Notice>
      )}
      {error && <ErrorBox>{error}</ErrorBox>}
      {warnings.map((w) => (
        <Notice key={w}>{w}</Notice>
      ))}

      {active && (
        <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-sm">
          <span className="flex items-center gap-2 font-mono tabular-nums">
            <span className="h-2 w-2 animate-pulse rounded-full bg-red-500" />
            {timestamp(Math.max(0, elapsed))}
          </span>
          <LevelMeter label="Me" level={levels.me} colorClass="bg-me" />
          <LevelMeter label="Them" level={levels.them} colorClass="bg-them" />
        </div>
      )}

      {active ? (
        segments.length ? (
          <Transcript segments={segments} follow />
        ) : (
          <p className="py-12 text-center text-sm text-zinc-500">Listening… text appears a moment after each pause.</p>
        )
      ) : (
        !modelMissing && (
          <div className="card space-y-2 p-5 text-sm text-zinc-600 dark:text-zinc-400">
            <p>
              Records your microphone (<b className="text-me">Me</b>) and your Mac's audio output (
              <b className="text-them">Them</b>), so it works with Zoom, Meet, Teams, or anything else, and no bot
              joins your call.
            </p>
            <p>
              Speech is transcribed on this Mac with Whisper. When you stop, a local model in Ollama writes the summary
              and action items. Nothing is uploaded.
            </p>
            <p className="text-zinc-500">
              Tip: use headphones, so your speakers don't leak into your mic and show up twice.
            </p>
          </div>
        )
      )}
    </div>
  );
}
