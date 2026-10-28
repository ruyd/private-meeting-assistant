import { useCallback, useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { ErrorBox, Spinner, Transcript } from "../components";
import { api, errorMessage, events, subscribe, type Meeting, type Segment } from "../lib/api";
import { dateTime, duration } from "../lib/format";

export default function MeetingPage() {
  const id = Number(useParams().id);
  const [params] = useSearchParams();
  const focusId = params.get("seg") ? Number(params.get("seg")) : null;
  const navigate = useNavigate();

  const [meeting, setMeeting] = useState<Meeting | null>(null);
  const [segments, setSegments] = useState<Segment[]>([]);
  const [filter, setFilter] = useState("");
  const [editing, setEditing] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);

  const load = useCallback(() => {
    api
      .getMeeting(id)
      .then(({ meeting, segments }) => {
        setMeeting(meeting);
        setSegments(segments);
      })
      .catch((e) => setError(errorMessage(e)));
  }, [id]);

  useEffect(load, [load]);

  useEffect(
    () =>
      subscribe(
        events.summaryStatus((s) => {
          if (s.meetingId === id) load();
        }),
      ),
    [id, load],
  );

  useEffect(() => {
    if (!flash) return;
    const t = setTimeout(() => setFlash(null), 2500);
    return () => clearTimeout(t);
  }, [flash]);

  const run = (fn: () => Promise<unknown>) => async () => {
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  if (!meeting) return error ? <div className="p-8"><ErrorBox>{error}</ErrorBox></div> : null;

  const saveTitle = run(async () => {
    await api.renameMeeting(id, titleDraft);
    setEditing(false);
    load();
  });

  const status = meeting.summaryStatus;
  const summarizing = status === "running";

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-6 p-8">
      <header className="space-y-1">
        {editing ? (
          <input
            className="input text-xl font-semibold"
            value={titleDraft}
            autoFocus
            onChange={(e) => setTitleDraft(e.target.value)}
            onBlur={saveTitle}
            onKeyDown={(e) => {
              if (e.key === "Enter") saveTitle();
              if (e.key === "Escape") setEditing(false);
            }}
          />
        ) : (
          <h1
            className="cursor-text text-xl font-semibold hover:text-accent"
            title="Click to rename"
            onClick={() => {
              setTitleDraft(meeting.title);
              setEditing(true);
            }}
          >
            {meeting.title}
          </h1>
        )}
        <div className="text-sm text-zinc-500">
          {dateTime(meeting.startedAt)} · {duration(meeting.durationMs)} · {meeting.segmentCount} lines
        </div>
        <div className="flex flex-wrap gap-2 pt-2">
          <button
            className="btn"
            onClick={run(async () => {
              await navigator.clipboard.writeText(await api.meetingMarkdown(id));
              setFlash("Copied as Markdown");
            })}
          >
            Copy Markdown
          </button>
          <button
            className="btn"
            onClick={run(async () => {
              const path = await api.exportMarkdown(id);
              setFlash(`Saved ${path.split("/").pop()}`);
            })}
          >
            Export to Downloads
          </button>
          {meeting.audioDir && (
            <button className="btn" onClick={run(() => api.revealAudio(id))}>
              Show audio
            </button>
          )}
          <div className="flex-1" />
          {confirmDelete ? (
            <>
              <button
                className="btn-danger"
                onClick={run(async () => {
                  await api.deleteMeeting(id);
                  navigate("/meetings");
                })}
              >
                Delete permanently
              </button>
              <button className="btn" onClick={() => setConfirmDelete(false)}>
                Cancel
              </button>
            </>
          ) : (
            <button className="btn-danger" onClick={() => setConfirmDelete(true)}>
              Delete
            </button>
          )}
        </div>
        {flash && <div className="text-sm text-green-700 dark:text-green-400">{flash}</div>}
      </header>

      {error && <ErrorBox>{error}</ErrorBox>}

      <section className="card space-y-4 p-5">
        <div className="flex items-center justify-between">
          <h2 className="font-semibold">Summary</h2>
          {meeting.segmentCount > 0 && (
            <button className="btn" disabled={summarizing} onClick={run(() => api.summarize(id))}>
              {summarizing ? (
                <>
                  <Spinner /> Summarizing…
                </>
              ) : meeting.summary ? (
                "Regenerate"
              ) : (
                "Summarize"
              )}
            </button>
          )}
        </div>

        {status.startsWith("error") && <ErrorBox>{status.replace(/^error:\s*/, "")}</ErrorBox>}

        {meeting.summary ? (
          <div className="selectable space-y-4 text-[15px] leading-relaxed">
            <p>{meeting.summary.summary}</p>
            {meeting.summary.decisions.length > 0 && (
              <div>
                <h3 className="mb-1 text-sm font-semibold text-zinc-500">Decisions</h3>
                <ul className="list-disc space-y-1 pl-5">
                  {meeting.summary.decisions.map((d, i) => (
                    <li key={i}>{d}</li>
                  ))}
                </ul>
              </div>
            )}
            {meeting.summary.actionItems.length > 0 && (
              <div>
                <h3 className="mb-1 text-sm font-semibold text-zinc-500">Action items</h3>
                <ul className="space-y-1">
                  {meeting.summary.actionItems.map((a, i) => (
                    <li key={i}>
                      <label className="flex cursor-pointer items-start gap-2">
                        <input
                          type="checkbox"
                          className="mt-1.5 accent-accent"
                          checked={a.done}
                          onChange={run(async () => setMeeting(await api.toggleActionItem(id, i)))}
                        />
                        <span className={a.done ? "text-zinc-400 line-through" : ""}>
                          {a.text}
                          {a.owner && <span className="ml-1.5 text-sm text-zinc-500">— {a.owner}</span>}
                        </span>
                      </label>
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </div>
        ) : (
          !summarizing &&
          !status.startsWith("error") && (
            <p className="text-sm text-zinc-500">
              {meeting.segmentCount > 0
                ? "No summary yet. It's generated locally with Ollama."
                : "Nothing was transcribed in this meeting."}
            </p>
          )
        )}
      </section>

      <section className="space-y-3">
        <div className="flex items-center justify-between gap-4">
          <h2 className="font-semibold">Transcript</h2>
          <input
            className="input max-w-60"
            placeholder="Filter transcript…"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
        </div>
        <Transcript segments={segments} filter={filter} focusId={focusId} />
      </section>
    </div>
  );
}
