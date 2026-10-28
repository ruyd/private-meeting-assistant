import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useRecording } from "../App";
import { ErrorBox, Highlight, SpeakerTag } from "../components";
import { api, errorMessage, type Meeting, type SearchHit } from "../lib/api";
import { dateTime, duration, timestamp } from "../lib/format";

export default function Meetings() {
  const rec = useRecording();
  const [meetings, setMeetings] = useState<Meeting[] | null>(null);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<SearchHit[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.listMeetings().then(setMeetings).catch((e) => setError(errorMessage(e)));
  }, [rec.status]);

  useEffect(() => {
    if (!query.trim()) {
      setHits(null);
      return;
    }
    const t = setTimeout(() => {
      api.search(query).then(setHits).catch((e) => setError(errorMessage(e)));
    }, 150);
    return () => clearTimeout(t);
  }, [query]);

  const grouped = useMemo(() => {
    if (!hits) return null;
    const map = new Map<number, { title: string; startedAt: string; hits: SearchHit[] }>();
    for (const h of hits) {
      const g = map.get(h.meetingId) ?? { title: h.meetingTitle, startedAt: h.startedAt, hits: [] };
      g.hits.push(h);
      map.set(h.meetingId, g);
    }
    return [...map.entries()];
  }, [hits]);

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-5 p-8">
      <input
        className="input text-base"
        placeholder="Search all meetings…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        autoFocus
      />
      {error && <ErrorBox>{error}</ErrorBox>}

      {grouped ? (
        grouped.length === 0 ? (
          <p className="py-8 text-center text-sm text-zinc-500">No results for “{query}”.</p>
        ) : (
          <div className="space-y-4">
            {grouped.map(([id, g]) => (
              <section key={id} className="card overflow-hidden">
                <div className="flex items-baseline justify-between border-b border-zinc-200 bg-zinc-50 px-4 py-2 dark:border-zinc-800 dark:bg-zinc-900">
                  <Link to={`/meetings/${id}`} className="font-medium hover:underline">
                    {g.title}
                  </Link>
                  <span className="text-xs text-zinc-500">{dateTime(g.startedAt)}</span>
                </div>
                <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {g.hits.slice(0, 8).map((h, i) => (
                    <li key={i}>
                      <Link
                        to={h.segmentId ? `/meetings/${id}?seg=${h.segmentId}` : `/meetings/${id}`}
                        className="flex gap-3 px-4 py-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                      >
                        <span className="w-14 shrink-0 text-right font-mono text-xs text-zinc-400">
                          {h.kind === "summary" ? "summary" : timestamp(h.startMs ?? 0)}
                        </span>
                        <span className="min-w-0">
                          {h.speaker && (
                            <>
                              <SpeakerTag speaker={h.speaker} />{" "}
                            </>
                          )}
                          <Highlight text={h.snippet} />
                        </span>
                      </Link>
                    </li>
                  ))}
                  {g.hits.length > 8 && (
                    <li className="px-4 py-2 text-xs text-zinc-500">+{g.hits.length - 8} more matches</li>
                  )}
                </ul>
              </section>
            ))}
          </div>
        )
      ) : meetings === null ? null : meetings.length === 0 ? (
        <div className="py-16 text-center text-sm text-zinc-500">
          No meetings yet.{" "}
          <Link to="/" className="text-accent underline">
            Record your first one
          </Link>
          .
        </div>
      ) : (
        <ul className="space-y-2">
          {meetings.map((m) => (
            <MeetingRow key={m.id} m={m} live={rec.meetingId === m.id} />
          ))}
        </ul>
      )}
    </div>
  );
}

function MeetingRow({ m, live }: { m: Meeting; live: boolean }) {
  const open = m.summary?.actionItems.filter((a) => !a.done).length ?? 0;
  return (
    <li>
      <Link
        to={live ? "/" : `/meetings/${m.id}`}
        className="card block px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/40"
      >
        <div className="flex items-baseline justify-between gap-3">
          <span className="truncate font-medium">{m.title}</span>
          <span className="shrink-0 text-xs text-zinc-500">{dateTime(m.startedAt)}</span>
        </div>
        <div className="mt-1 flex gap-3 text-xs text-zinc-500">
          {live ? (
            <span className="text-red-500">● recording</span>
          ) : (
            <span>{duration(m.durationMs)}</span>
          )}
          <span>{m.segmentCount} lines</span>
          {open > 0 && <span>{open} open action items</span>}
          {m.summaryStatus === "running" && <span>summarizing…</span>}
        </div>
        {m.summary && <p className="mt-1.5 line-clamp-2 text-sm text-zinc-600 dark:text-zinc-400">{m.summary.summary}</p>}
      </Link>
    </li>
  );
}
