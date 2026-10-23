import { UNTRUSTED_END, UNTRUSTED_START } from "./markup";

/**
 * A tool request as parsed from a noche-tool fence. Requests are only ever
 * produced by StreamInterpreter for well-formed fences OUTSIDE untrusted
 * sentinel spans; everything inside a span (and every malformed fence) is
 * emitted as inert text instead. Downstream consumers (gate, orchestrator)
 * can treat this type as trusted-by-construction: it is the only path from
 * model output to tool execution.
 */
export interface ToolRequest {
  name: string;
  args: Record<string, unknown>;
}

export interface InterpreterCallbacks {
  onText(text: string): void;
  onToolRequest(request: ToolRequest): void;
}

const TOOL_FENCE_OPEN = "```noche-tool\n";
const FENCE_CLOSE = "```";

type Mode = "text" | "untrusted" | "tool";

/** Longest suffix of buf that is a proper prefix of marker (0 when none). */
function partialTailLength(buf: string, marker: string): number {
  const max = Math.min(marker.length - 1, buf.length);
  for (let k = max; k >= 1; k--) {
    if (buf.endsWith(marker.slice(0, k))) return k;
  }
  return 0;
}

/**
 * Strict tool-request shape: {"name": string, "args": object}. Anything else
 * (bad JSON, arrays, primitives, missing fields) yields null and the whole
 * fence travels as inert text, never as a command.
 */
export function parseToolRequest(body: string): ToolRequest | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const record = parsed as Record<string, unknown>;
  if (typeof record.name !== "string") return null;
  if (typeof record.args !== "object" || record.args === null || Array.isArray(record.args)) {
    return null;
  }
  return { name: record.name, args: record.args as Record<string, unknown> };
}

/**
 * Incremental interpreter for a model's text stream. Feed chunks as they
 * arrive; plain text flows to onText and well-formed ```noche-tool fences
 * become onToolRequest calls. Sentinel spans (see markup.ts) may span chunk
 * boundaries: tool syntax inside them is page data and is re-emitted as text.
 * Unterminated fences at stream end stay text. All matchers are buffered
 * against splits, so chunking never changes the interpretation.
 */
export class StreamInterpreter {
  private buf = "";
  private mode: Mode = "text";
  private toolBody = "";
  private done = false;

  constructor(private readonly cb: InterpreterCallbacks) {}

  feed(chunk: string): void {
    if (this.done) throw new Error("interpreter already ended");
    this.buf += chunk;
    this.drain(false);
  }

  end(): void {
    if (this.done) throw new Error("interpreter already ended");
    this.done = true;
    this.drain(true);
  }

  private emitText(text: string): void {
    if (text !== "") this.cb.onText(text);
  }

  /** Progress until no more can be decided; returns to the caller otherwise. */
  private drain(final: boolean): void {
    for (;;) {
      if (this.mode === "text") {
        if (!this.drainText(final)) return;
      } else if (this.mode === "untrusted") {
        if (!this.drainUntrusted(final)) return;
      } else if (!this.drainTool(final)) {
        return;
      }
    }
  }

  private drainText(final: boolean): boolean {
    const startIdx = this.buf.indexOf(UNTRUSTED_START);
    const fenceIdx = this.buf.indexOf(TOOL_FENCE_OPEN);
    if (startIdx !== -1 && (fenceIdx === -1 || startIdx < fenceIdx)) {
      this.emitText(this.buf.slice(0, startIdx) + UNTRUSTED_START);
      this.buf = this.buf.slice(startIdx + UNTRUSTED_START.length);
      this.mode = "untrusted";
      return true;
    }
    if (fenceIdx !== -1) {
      this.emitText(this.buf.slice(0, fenceIdx));
      this.buf = this.buf.slice(fenceIdx + TOOL_FENCE_OPEN.length);
      this.mode = "tool";
      this.toolBody = "";
      return true;
    }
    const hold = final
      ? 0
      : Math.max(
          partialTailLength(this.buf, UNTRUSTED_START),
          partialTailLength(this.buf, TOOL_FENCE_OPEN),
        );
    const emitLength = this.buf.length - hold;
    this.emitText(this.buf.slice(0, emitLength));
    this.buf = this.buf.slice(emitLength);
    return false;
  }

  private drainUntrusted(final: boolean): boolean {
    const endIdx = this.buf.indexOf(UNTRUSTED_END);
    if (endIdx !== -1) {
      // Inside a span everything is page data: markers included, verbatim.
      this.emitText(this.buf.slice(0, endIdx) + UNTRUSTED_END);
      this.buf = this.buf.slice(endIdx + UNTRUSTED_END.length);
      this.mode = "text";
      return true;
    }
    const hold = final ? 0 : partialTailLength(this.buf, UNTRUSTED_END);
    const emitLength = this.buf.length - hold;
    this.emitText(this.buf.slice(0, emitLength));
    this.buf = this.buf.slice(emitLength);
    return false;
  }

  private drainTool(final: boolean): boolean {
    const closeIdx = this.buf.indexOf(FENCE_CLOSE);
    if (closeIdx !== -1) {
      const body = this.toolBody + this.buf.slice(0, closeIdx);
      this.buf = this.buf.slice(closeIdx + FENCE_CLOSE.length);
      this.mode = "text";
      const request = parseToolRequest(body);
      if (request === null) this.emitText(TOOL_FENCE_OPEN + body + FENCE_CLOSE);
      else this.cb.onToolRequest(request);
      return true;
    }
    // Hold back a possible partial closer so a fence split between backticks
    // still closes (chunk boundaries can fall anywhere, including inside ```).
    const hold = final ? 0 : partialTailLength(this.buf, FENCE_CLOSE);
    const keep = this.buf.length - hold;
    this.toolBody += this.buf.slice(0, keep);
    this.buf = this.buf.slice(keep);
    if (final) {
      // Unterminated fence: stays text, exactly as it was written.
      this.emitText(TOOL_FENCE_OPEN + this.toolBody);
    }
    return false;
  }
}
