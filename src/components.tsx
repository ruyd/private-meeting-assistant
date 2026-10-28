import { useEffect, useRef } from "react";
import type { Segment } from "./lib/api";
import { timestamp } from "./lib/format";

/** Renders a search snippet whose matches are wrapped in \u0001 … \u0002. */
export function Highlight({ text }: { text: string }) {
  const parts = text.split(/(\u0001[^\u0002]*\u0002)/);
  return (
    <>
      {parts.map((p, i) =>
        p.startsWith("\u0001") ? <mark key={i}>{p.slice(1, -1)}</mark> : <span key={i}>{p}</span>,
      )}
    </>
  );
}

/** Case-insensitive highlight of a plain filter string. */
export function FilterHighlight({ text, filter }: { text: string; filter: string }) {
  if (!filter) return <>{text}</>;
  const escaped = filter.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const parts = text.split(new RegExp(`(${escaped})`, "ig"));
  return (
    <>
      {parts.map((p, i) => (i % 2 === 1 ? <mark key={i}>{p}</mark> : <span key={i}>{p}</span>))}
    </>
  );
}

export function SpeakerTag({ speaker }: { speaker: string }) {
  const color = speaker === "Me" ? "text-me" : "text-them";
  return <span className={`text-xs font-semibold ${color}`}>{speaker}</span>;
}

export function Transcript({
  segments,
  filter = "",
  focusId,
  follow = false,
}: {
  segments: Segment[];
  filter?: string;
  focusId?: number | null;
  /** Keep scrolled to the bottom while new segments arrive (unless the user scrolled up). */
  follow?: boolean;
}) {
  const endRef = useRef<HTMLDivElement>(null);
  const focusRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!follow) return;
    const scroller = endRef.current?.closest("main");
    if (!scroller) return;
    const nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 200;
    if (nearBottom) endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [segments.length, follow]);

  useEffect(() => {
    focusRef.current?.scrollIntoView({ block: "center" });
  }, [focusId]);

  const shown = filter
    ? segments.filter((s) => s.text.toLowerCase().includes(filter.toLowerCase()))
    : segments;

  return (
    <div className="selectable space-y-3">
      {shown.map((s) => (
        <div
          key={s.id}
          ref={s.id === focusId ? focusRef : undefined}
          className={`grid grid-cols-[3.5rem_1fr] gap-3 rounded-md px-2 py-1 ${
            s.id === focusId ? "bg-accent-soft" : ""
          }`}
        >
          <div className="pt-0.5 text-right font-mono text-xs text-zinc-400 tabular-nums">
            {timestamp(s.startMs)}
          </div>
          <div>
            <SpeakerTag speaker={s.speaker} />
            <p className="text-[15px] leading-relaxed">
              <FilterHighlight text={s.text} filter={filter} />
            </p>
          </div>
        </div>
      ))}
      {filter && shown.length === 0 && <p className="px-2 text-sm text-zinc-500">No lines match “{filter}”.</p>}
      <div ref={endRef} />
    </div>
  );
}

export function LevelMeter({ label, level, colorClass }: { label: string; level: number; colorClass: string }) {
  // Map RMS (≈0.001–0.3) to 0–100% on a log scale.
  const db = 20 * Math.log10(Math.max(level, 1e-4));
  const pct = Math.min(100, Math.max(0, ((db + 60) / 50) * 100));
  return (
    <div className="flex items-center gap-2">
      <span className="w-10 text-xs text-zinc-500">{label}</span>
      <div className="h-1.5 w-32 overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800">
        <div className={`h-full ${colorClass} transition-[width] duration-100`} style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

export function Spinner() {
  return (
    <span className="inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" />
  );
}

export function ErrorBox({ children }: { children: React.ReactNode }) {
  return (
    <div className="selectable rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm whitespace-pre-wrap text-red-800 dark:border-red-900 dark:bg-red-950/50 dark:text-red-300">
      {children}
    </div>
  );
}

export function Notice({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
      {children}
    </div>
  );
}
