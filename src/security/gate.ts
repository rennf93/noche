import type { ToolRequest } from "./interpreter";

/** Tools are read-only or mutating; every write needs explicit user consent. */
export type ToolKind = "read" | "write";

export interface ToolSpec {
  name: string;
  kind: ToolKind;
  description: string;
}

export type SpecLookup = (name: string) => ToolSpec | undefined;

export type GateVerdict = "allow" | "refuse";
export type GateReason =
  | "read-allowed"
  | "consent-granted"
  | "unknown-tool"
  | "consent-denied";

export interface GateResult {
  verdict: GateVerdict;
  reason: GateReason;
}

/**
 * Consent gate for one parsed tool request. Reads pass without prompting;
 * writes always wait for the user's explicit yes via the consent callback;
 * unknown tool names are refused outright.
 *
 * Untrusted page content can never be the sole trigger for a write, and this
 * is enforced structurally rather than by inspecting content: the gate only
 * ever sees requests that StreamInterpreter parsed from fences OUTSIDE
 * untrusted sentinel spans (tool syntax inside a span is emitted as inert
 * text and never becomes a ToolRequest), and a write still stops here until
 * the user consents. Page text alone can at most cause a request that the
 * user must approve.
 */
export async function gateRequest(
  request: ToolRequest,
  lookup: SpecLookup,
  consent: (request: ToolRequest) => Promise<boolean>,
): Promise<GateResult> {
  const spec = lookup(request.name);
  if (spec === undefined) return { verdict: "refuse", reason: "unknown-tool" };
  if (spec.kind === "read") return { verdict: "allow", reason: "read-allowed" };
  const granted = await consent(request);
  return granted
    ? { verdict: "allow", reason: "consent-granted" }
    : { verdict: "refuse", reason: "consent-denied" };
}
