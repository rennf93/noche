import type { ToolRequest } from "../security/interpreter";
import { parseRailPortMessage, type RailMessage, type RailPortMessage, type SendBinding } from "./rail-protocol";
import type { ChatEvent } from "./orchestrator";

/**
 * The chat rail's behavior, isolated from the DOM so the whole surface is
 * unit-testable: turns stream in through port messages, write-tool requests
 * park the run on a consent prompt, stop aborts the run, and every mutation
 * fires onChange exactly once for the render layer. The entrypoint renders
 * snapshots; it holds no behavior of its own.
 */

export type TurnStatus = "streaming" | "done" | "stopped" | "error";

/** One tool the model asked for while answering, with its outcome when known. */
export interface ToolActivity {
  request: ToolRequest;
  /** Undefined while the tool has not produced a result yet. */
  ok?: boolean;
  /** Refusal or execution error, when ok is false. */
  error?: string;
}

export interface RailTurn {
  id: number;
  role: "user" | "assistant";
  text: string;
  status: TurnStatus;
  error?: string;
  tools: ToolActivity[];
}

export type RailPhase = "empty" | "idle" | "streaming" | "consent";

/** A write-tool request parked at the consent prompt (approve once, or deny). */
export interface ConsentPrompt {
  /** The run the prompt belongs to; echoed back in the reply. */
  id: number;
  requestId: number;
  request: ToolRequest;
}

export interface RailSnapshot {
  phase: RailPhase;
  /** True while a run is in flight (streaming or parked on consent). */
  busy: boolean;
  turns: RailTurn[];
  consent: ConsentPrompt | null;
}

export interface RailModelDeps {
  /** Transport for rail-to-background messages (the chat port). */
  post(message: RailMessage): void;
  /** Change hook for the render layer. */
  onChange(): void;
}

export class RailModel {
  private turns: RailTurn[] = [];
  private phase: RailPhase = "empty";
  private runId: number | null = null;
  private consent: ConsentPrompt | null = null;
  private nextRunId = 1;
  private nextTurnId = 1;

  constructor(private readonly deps: RailModelDeps) {}

  /** Live state for the render layer; turns are mutated in place. */
  snapshot(): RailSnapshot {
    return {
      phase: this.phase,
      busy: this.phase === "streaming" || this.phase === "consent",
      turns: this.turns,
      consent: this.consent,
    };
  }

  /**
   * Queue a user turn. False (no-op) mid-run or for blank text. The optional
   * binding is the picker's per-conversation override, carried on the wire so
   * the run binds to exactly what the user picked at send time.
   */
  send(text: string, binding?: SendBinding): boolean {
    if (this.phase === "streaming" || this.phase === "consent") return false;
    if (text.trim() === "") return false;
    const id = this.nextRunId++;
    this.turns.push(
      { id: this.nextTurnId++, role: "user", text, status: "done", tools: [] },
      { id: this.nextTurnId++, role: "assistant", text: "", status: "streaming", tools: [] },
    );
    this.runId = id;
    this.phase = "streaming";
    this.deps.post({ type: "noche:chat-send", id, text, binding });
    this.deps.onChange();
    return true;
  }

  /** Abort the active run (stop button, Escape). No-op when idle. */
  stop(): void {
    if (this.runId === null) return;
    this.deps.post({ type: "noche:chat-stop", id: this.runId });
    this.settle("stopped");
  }

  approveConsent(): void {
    this.replyConsent(true);
  }

  denyConsent(): void {
    this.replyConsent(false);
  }

  /** Clear the conversation. No-op mid-run; stop first. */
  newChat(): void {
    if (this.phase === "streaming" || this.phase === "consent") return;
    this.turns = [];
    this.phase = "empty";
    this.deps.onChange();
  }

  /** Entry point for raw port payloads; malformed ones are dropped. */
  onPortMessage(raw: unknown): void {
    const message = parseRailPortMessage(raw);
    if (message !== null) this.accept(message);
  }

  private accept(message: RailPortMessage): void {
    if (message.id !== this.runId) return; // stale or unknown run
    if (message.type === "noche:consent-request") {
      this.consent = {
        id: message.id,
        requestId: message.requestId,
        request: message.request,
      };
      this.phase = "consent";
    } else {
      this.applyEvent(message.event);
    }
    this.deps.onChange();
  }

  private replyConsent(approve: boolean): void {
    const prompt = this.consent;
    if (prompt === null) return;
    this.consent = null;
    this.phase = "streaming";
    this.deps.post({
      type: "noche:consent-reply",
      id: prompt.id,
      requestId: prompt.requestId,
      approve,
    });
    this.deps.onChange();
  }

  /**
   * The active run's assistant turn is always the last turn: send() pushes it
   * last, nothing appends turns mid-run, and events only pass the run-id gate
   * while a run is active.
   */
  private applyEvent(event: ChatEvent): void {
    const turn = this.turns[this.turns.length - 1];
    switch (event.type) {
      case "text":
        turn.text += event.text;
        return;
      case "tool-request":
        turn.tools.push({ request: event.request });
        return;
      case "tool-result": {
        const activity = turn.tools.find(
          (candidate) =>
            candidate.ok === undefined && candidate.request.name === event.request.name,
        );
        if (activity === undefined) return;
        activity.ok = event.result.ok;
        if (!event.result.ok) activity.error = event.result.error;
        return;
      }
      case "error":
        turn.error = event.message;
        this.settle("error");
        return;
      case "done":
        this.settle("done");
        return;
    }
  }

  /** Close the active run: the streaming turn keeps its text and gets a status. */
  private settle(status: TurnStatus): void {
    this.turns[this.turns.length - 1].status = status;
    this.runId = null;
    this.consent = null;
    this.phase = "idle";
  }
}
