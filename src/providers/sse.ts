/**
 * Incremental SSE line parser. Feed it decoded text chunks in arrival order;
 * it yields complete events and buffers partial lines between feeds. Handles
 * LF and CRLF, comment lines, multi-line data, and empty keep-alive events.
 */
export interface SseEvent {
  event?: string;
  data: string;
}

export function createSseParser() {
  let buffer = "";
  const events: SseEvent[] = [];
  let pending: { event?: string; dataLines: string[] } | null = null;

  const flushPending = (): void => {
    if (pending) {
      events.push({
        event: pending.event,
        data: pending.dataLines.join("\n"),
      });
      pending = null;
    }
  };

  const handleLine = (line: string): void => {
    if (line === "") {
      flushPending();
      return;
    }
    if (line.startsWith(":")) return;
    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "data") {
      pending = pending ?? { dataLines: [] };
      pending.dataLines.push(value);
      return;
    }
    if (field === "event") {
      pending = pending ?? { dataLines: [] };
      pending.event = value;
    }
  };

  return {
    feed(chunk: string): SseEvent[] {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.search(/\r?\n/)) !== -1) {
        const sep = buffer.startsWith("\r\n", newline) ? 2 : 1;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + sep);
        handleLine(line);
      }
      const out = events.splice(0, events.length);
      return out;
    },
    /** Flush a trailing line when the stream ends without a final newline. */
    end(): SseEvent[] {
      if (buffer !== "") {
        handleLine(buffer);
        buffer = "";
      }
      flushPending();
      return events.splice(0, events.length);
    },
  };
}
