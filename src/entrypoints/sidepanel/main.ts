import "../../ui/tokens.css";
import "../../ui/rail.css";
import {
  CHAT_PORT,
  CONTEXT_REQUEST,
  parseRailContextResponse,
} from "../../chat/rail-protocol";
import { RailModel, type RailTurn } from "../../chat/rail-model";
import { PickerModel } from "../../chat/picker-model";
import {
  PICKER_REQUEST,
  PICKER_SET,
  SKILLS_REQUEST,
  parsePickerFleetResponse,
  parsePickerSetResponse,
  parseSkillsResponse,
} from "../../chat/picker-protocol";
import { SlashMenuModel } from "../../chat/slash-menu";
import { parseSurfaceMessage } from "../../chat/protocol";
import type { SkillSuggestion } from "../../skills/registry";
import { appendTextDelta, chipGlyph, shouldStickToBottom } from "../../ui/dom";

/**
 * The chat rail surface: a thin render layer over RailModel, PickerModel and
 * SlashMenuModel. Behavior lives in src/chat and src/skills (unit-tested);
 * this file owns DOM reconciliation, the chat port, the one-shot context
 * load, the settings-backed provider/model dropdowns (fleet and commits ride
 * parsed round trips to the background, chat/picker-protocol.ts), and the
 * pending-question handshake from chat/protocol.ts (a selection ask that
 * arrived before the panel opened).
 */

function el<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (found === null) throw new Error(`missing #${id}`);
  return found as T;
}

const conversation = el<HTMLDivElement>("conversation");
const emptyHint = el<HTMLDivElement>("empty");
const newChatBtn = el<HTMLButtonElement>("new-chat");
const modelBadge = el<HTMLSpanElement>("model-badge");
const composerCard = el<HTMLDivElement>("composer-card");
const composerInput = el<HTMLTextAreaElement>("composer-input");
const sendBtn = el<HTMLButtonElement>("send");
const consentCard = el<HTMLDivElement>("consent-card");
const consentTitle = el<HTMLDivElement>("consent-title");
const consentArgs = el<HTMLPreElement>("consent-args");
const consentApprove = el<HTMLButtonElement>("consent-approve");
const consentDeny = el<HTMLButtonElement>("consent-deny");
const contextChip = el<HTMLDivElement>("context-chip");
const chipFavicon = el<HTMLSpanElement>("chip-favicon");
const chipTitle = el<HTMLSpanElement>("chip-title");
const chipOrigin = el<HTMLSpanElement>("chip-origin");
const pickerRow = el<HTMLDivElement>("picker-row");
const pickProvider = el<HTMLSelectElement>("pick-provider");
const pickModel = el<HTMLSelectElement>("pick-model");
const slashMenu = el<HTMLDivElement>("slash-menu");

const port = browser.runtime.connect({ name: CHAT_PORT });

interface TurnDom {
  root: HTMLDivElement;
  bubble: HTMLDivElement;
  text: HTMLDivElement;
  note: HTMLDivElement;
  thinking: HTMLDivElement;
  tools: HTMLDivElement;
  renderedLength: number;
}

const turnDom = new Map<number, TurnDom>();

function fadeNextFrame(span: HTMLSpanElement): void {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => span.classList.remove("chunk-enter"));
  });
}

function buildTurnDom(turn: RailTurn): TurnDom {
  const doc = document;
  const root = doc.createElement("div");
  root.className = `turn turn-${turn.role}`;
  const bubble = doc.createElement("div");
  bubble.className = "bubble";
  const text = doc.createElement("div");
  text.className = "turn-text";
  const thinking = doc.createElement("div");
  thinking.className = "thinking";
  thinking.setAttribute("aria-hidden", "true");
  for (let i = 0; i < 3; i++) {
    const dot = doc.createElement("span");
    dot.className = "thinking-dot";
    thinking.appendChild(dot);
  }
  const tools = doc.createElement("div");
  tools.className = "turn-tools";
  const note = doc.createElement("div");
  note.className = "turn-note";
  note.hidden = true;
  bubble.append(text, thinking, tools, note);
  root.appendChild(bubble);
  conversation.appendChild(root);
  return { root, bubble, text, note, thinking, tools, renderedLength: 0 };
}

function renderTools(turn: RailTurn, dom: TurnDom): void {
  if (dom.tools.childElementCount === turn.tools.length) return;
  dom.tools.replaceChildren();
  for (const activity of turn.tools) {
    const line = document.createElement("div");
    line.className = "tool-line";
    const dot = document.createElement("span");
    dot.className = "tool-dot";
    if (activity.ok !== undefined) dot.dataset.ok = String(activity.ok);
    line.appendChild(dot);
    const label = document.createElement("span");
    label.textContent =
      activity.ok === undefined
        ? `${activity.request.name}: waiting`
        : activity.ok === true
          ? `${activity.request.name}: done`
          : `${activity.request.name}: ${activity.error ?? "refused"}`;
    line.appendChild(label);
    dom.tools.appendChild(line);
  }
}

function renderTurn(turn: RailTurn): void {
  let dom = turnDom.get(turn.id);
  if (dom === undefined) {
    dom = buildTurnDom(turn);
    turnDom.set(turn.id, dom);
  }
  const chunk = appendTextDelta(dom.text, turn.text, dom.renderedLength);
  if (chunk !== null) fadeNextFrame(chunk.span);
  dom.renderedLength = turn.text.length;
  dom.thinking.hidden = !(turn.role === "assistant" && turn.status === "streaming" && turn.text === "");
  renderTools(turn, dom);
  if (turn.status === "error") {
    dom.note.dataset.kind = "error";
    dom.note.textContent = turn.error ?? "something went wrong";
    dom.note.hidden = false;
  } else if (turn.status === "stopped") {
    dom.note.removeAttribute("data-kind");
    dom.note.textContent = "Stopped";
    dom.note.hidden = false;
  } else {
    dom.note.hidden = true;
  }
}

let lastRenderedConsentId: number | null = null;

function renderConsent(snapshot: ReturnType<RailModel["snapshot"]>): void {
  const prompt = snapshot.consent;
  if (prompt === null) {
    consentCard.hidden = true;
    lastRenderedConsentId = null;
    return;
  }
  const fresh = prompt.requestId !== lastRenderedConsentId;
  consentTitle.textContent = `Allow ${prompt.request.name}?`;
  consentArgs.textContent = JSON.stringify(prompt.request.args, null, 2);
  if (fresh) {
    consentCard.classList.add("enter");
    requestAnimationFrame(() => {
      requestAnimationFrame(() => consentCard.classList.remove("enter"));
    });
    lastRenderedConsentId = prompt.requestId;
  }
  consentCard.hidden = false;
}

function render(): void {
  const snapshot = model.snapshot();
  const stick = shouldStickToBottom(conversation);
  emptyHint.hidden = snapshot.turns.length !== 0;
  newChatBtn.hidden = snapshot.turns.length === 0;
  const seen = new Set<number>();
  for (const turn of snapshot.turns) {
    seen.add(turn.id);
    renderTurn(turn);
  }
  for (const [id, dom] of turnDom) {
    if (!seen.has(id)) {
      dom.root.remove();
      turnDom.delete(id);
    }
  }
  composerCard.classList.toggle("busy", snapshot.busy);
  sendBtn.setAttribute("aria-label", snapshot.busy ? "Stop" : "Send");
  updateSendEnabled();
  renderConsent(snapshot);
  if (stick) conversation.scrollTop = conversation.scrollHeight;
}

const model = new RailModel({
  post: (message) => {
    try {
      port.postMessage(message);
    } catch {
      // Port closed mid-send: the disconnect handler has already stopped the run.
    }
  },
  onChange: render,
});

port.onMessage.addListener((raw: unknown) => model.onPortMessage(raw));
port.onDisconnect.addListener(() => {
  model.stop();
  modelBadge.textContent = "Noche (reconnect: reopen the panel)";
});

/** Provider/model picker: settings-fed dropdowns, persisted via the background. */
const picker = new PickerModel({
  loadFleet: async () => {
    const raw: unknown = await browser.runtime.sendMessage({ type: PICKER_REQUEST });
    const parsed = parsePickerFleetResponse(raw);
    if (!parsed.ok) throw new Error(parsed.error);
    return parsed.fleet;
  },
  commit: async (providerId, modelId) => {
    const raw: unknown = await browser.runtime.sendMessage({
      type: PICKER_SET,
      providerId,
      modelId,
    });
    const parsed = parsePickerSetResponse(raw);
    if (!parsed.ok) throw new Error(parsed.error);
    return parsed.fleet;
  },
  onChange: renderPicker,
});

function option(value: string, label: string): HTMLOptionElement {
  const node = document.createElement("option");
  node.value = value;
  node.textContent = label;
  return node;
}

function renderPicker(): void {
  const snapshot = picker.snapshot();
  pickerRow.hidden = !snapshot.ready;
  if (!snapshot.ready) return;
  pickProvider.replaceChildren(
    ...snapshot.providers.map((provider) => option(provider.id, provider.label)),
  );
  pickProvider.value = snapshot.providerId;
  const selected = snapshot.providers.find((provider) => provider.id === snapshot.providerId);
  pickModel.replaceChildren(
    ...(selected?.models ?? []).map((candidate) => option(candidate.id, candidate.label)),
  );
  pickModel.value = snapshot.modelId;
  // The header badge mirrors the live selection (same data the send binds to).
  const model = selected?.models.find((candidate) => candidate.id === snapshot.modelId);
  if (model !== undefined) modelBadge.textContent = model.label;
}

pickProvider.addEventListener("change", () => {
  void picker.select(pickProvider.value);
});
pickModel.addEventListener("change", () => {
  void picker.select(pickProvider.value, pickModel.value);
});

/** Skills slash-menu: suggestions while the composer holds a slash token. */
let availableSkills: SkillSuggestion[] = [];
const slash = new SlashMenuModel(() => availableSkills);

function renderSlash(): void {
  if (!slash.isOpen()) {
    slashMenu.hidden = true;
    slashMenu.replaceChildren();
    return;
  }
  const active = slash.activeIndex();
  slashMenu.replaceChildren(
    ...slash.list().map((item, index) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "slash-item";
      if (index === active) row.classList.add("active");
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        applySlash(index);
      });
      const name = document.createElement("span");
      name.className = "slash-item-name";
      name.textContent = `/${item.name}`;
      const description = document.createElement("span");
      description.className = "slash-item-desc";
      description.textContent = item.description;
      row.append(name, description);
      return row;
    }),
  );
  slashMenu.hidden = false;
}

/** Apply a suggestion (active row or explicit click): composer becomes "/name ". */
function applySlash(index?: number): void {
  const applied = slash.apply(index);
  if (applied === null) return;
  composerInput.value = applied;
  slash.onInput(composerInput.value);
  renderSlash();
  autosize();
  updateSendEnabled();
  composerInput.focus();
}

function updateSendEnabled(): void {
  sendBtn.disabled = !model.snapshot().busy && composerInput.value.trim() === "";
}

function autosize(): void {
  composerInput.style.height = "auto";
  composerInput.style.height = `${Math.min(composerInput.scrollHeight, 132)}px`;
}

function submitOrStop(): void {
  if (model.snapshot().busy) {
    model.stop();
    return;
  }
  // A slash token being typed is a command choice, not a message: commit the
  // highlighted suggestion instead of sending "/sum" as text.
  if (slash.isOpen()) {
    applySlash();
    return;
  }
  const text = composerInput.value;
  if (!model.send(text, picker.binding() ?? undefined)) return;
  composerInput.value = "";
  autosize();
  updateSendEnabled();
}

sendBtn.addEventListener("click", submitOrStop);
composerInput.addEventListener("input", () => {
  autosize();
  updateSendEnabled();
  slash.onInput(composerInput.value);
  renderSlash();
});
composerInput.addEventListener("keydown", (event) => {
  if (slash.isOpen()) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      slash.move(event.key === "ArrowDown" ? 1 : -1);
      renderSlash();
      return;
    }
    if (event.key === "Enter" || event.key === "Tab") {
      event.preventDefault();
      applySlash();
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      slash.close();
      renderSlash();
      return;
    }
  }
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    submitOrStop();
  }
  if (event.key === "Escape" && model.snapshot().busy) model.stop();
});
newChatBtn.addEventListener("click", () => model.newChat());
consentApprove.addEventListener("click", () => model.approveConsent());
consentDeny.addEventListener("click", () => model.denyConsent());

/** One-shot context: model badge for the bound provider/model, tab chip. */
async function loadContext(): Promise<void> {
  try {
    const raw: unknown = await browser.runtime.sendMessage({ type: CONTEXT_REQUEST });
    const response = parseRailContextResponse(raw);
    if (!response.ok) throw new Error(response.error);
    modelBadge.textContent = response.context.modelLabel;
    modelBadge.title = `${response.context.providerLabel} - ${response.context.modelLabel}`;
    const chip = response.context.chip;
    if (chip !== null) {
      chipTitle.textContent = chip.title;
      chipOrigin.textContent = chip.origin;
      chipFavicon.textContent = chipGlyph(chip.origin);
      contextChip.hidden = false;
    }
  } catch {
    modelBadge.textContent = "Noche";
  }
}

/** Selection-ask handshake (chat/protocol.ts): live push and open-time pull. */
function prefill(text: string): void {
  composerInput.value = text;
  autosize();
  updateSendEnabled();
  composerInput.focus();
}

browser.runtime.onMessage.addListener((raw: unknown) => {
  const surface = parseSurfaceMessage(raw);
  if (surface?.type === "noche:pending-question" && surface.question !== null) {
    prefill(surface.question.text);
  }
  return undefined;
});

void (async () => {
  try {
    const raw: unknown = await browser.runtime.sendMessage({
      type: "noche:take-pending-question",
    });
    const surface = parseSurfaceMessage(raw);
    if (surface?.type === "noche:pending-question" && surface.question !== null) {
      prefill(surface.question.text);
    }
  } catch {
    // Background restarting: nothing queued is not an error.
  }
})();

render();
void loadContext();

/** Settings fleet for the picker; skill summaries for the slash-menu. */
void (async () => {
  try {
    await picker.load();
  } catch {
    // Background unreachable: the dropdowns stay hidden rather than guessing.
  }
})();
void (async () => {
  try {
    const raw: unknown = await browser.runtime.sendMessage({ type: SKILLS_REQUEST });
    const parsed = parseSkillsResponse(raw);
    if (parsed.ok) availableSkills = parsed.skills;
  } catch {
    // Background unreachable: the menu stays empty rather than guessing.
  }
})();

composerInput.focus();
requestAnimationFrame(() => document.body.classList.add("ready"));
