import { suggestSkills, type SkillSuggestion } from "../skills/registry";

/**
 * The composer's skills slash-menu, isolated from the DOM: while the composer
 * holds a bare slash token at position zero ("/", "/sum", no whitespace yet),
 * the menu lists matching skills; arrow keys move, Enter/Tab apply, any other
 * text (a space, a non-slash first character) closes it. Selection state lives
 * here so the entrypoint only renders.
 */

/** Menu length cap: six rows scroll no panel, whatever the registry size. */
export const MAX_SLASH_ITEMS = 6;

/** True while the composer text is a slash command still being typed. */
export function isSlashToken(text: string): boolean {
  return text.startsWith("/") && !/\s/.test(text);
}

export class SlashMenuModel {
  private items: SkillSuggestion[] = [];
  private query = "";
  private active = -1;

  /** Skills come from a getter so late loads (registry fetch) appear live. */
  constructor(private readonly source: () => readonly SkillSuggestion[]) {}

  /** Recompute the suggestion list from the composer text. */
  onInput(text: string): void {
    if (!isSlashToken(text)) {
      this.close();
      return;
    }
    const query = text.slice(1);
    this.query = query;
    this.items = suggestSkills(query, this.source(), MAX_SLASH_ITEMS);
    this.active = this.items.length > 0 ? 0 : -1;
  }

  isOpen(): boolean {
    return this.items.length > 0;
  }

  list(): readonly SkillSuggestion[] {
    return this.items;
  }

  activeIndex(): number {
    return this.active;
  }

  /** The query currently filtered on (text after the slash); "" when closed. */
  currentQuery(): string {
    return this.query;
  }

  /**
   * Move the active row by delta (arrow keys); clamps at both ends. False
   * when there is nothing to move (closed) or the move would not change it.
   */
  move(delta: number): boolean {
    if (this.items.length === 0) return false;
    const next = Math.min(this.items.length - 1, Math.max(0, this.active + delta));
    if (next === this.active) return false;
    this.active = next;
    return true;
  }

  /**
   * Composer text for the active row (or an explicit index): "/name " ready
   * for the rest of the message. Null when closed or the index has no row.
   */
  apply(index?: number): string | null {
    if (this.items.length === 0) return null;
    const item = this.items[index ?? this.active];
    if (item === undefined) return null;
    return `/${item.name} `;
  }

  /** Close and clear; the next input event reopens from scratch. */
  close(): void {
    this.items = [];
    this.active = -1;
    this.query = "";
  }
}
