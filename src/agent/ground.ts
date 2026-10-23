/**
 * Aria-style grounding: pick the selector for an element the planner described
 * in role/name/text terms, from a serialized page outline. The heuristic is a
 * fixed scoring table, so grounding is deterministic and fully unit-testable:
 * the same outline and description always ground to the same selector, and
 * document order (earliest element) breaks every tie.
 *
 * Trust note: the outline must come from our own page serializer, never from
 * page-provided data. Grounding only picks among selectors the outline lists;
 * a hostile page cannot inject a selector it did not already control.
 */

/** One serialized element: effective aria role, accessible name, current value, visible text. */
export interface OutlineElement {
  role?: string;
  name?: string;
  /** The concrete CSS selector returned when this element wins grounding. */
  selector: string;
  /** Current value for form fields (textbox, searchbox, combobox). */
  value?: string;
  /** Visible inner text for everything else. */
  text?: string;
}

export interface PageOutline {
  /** Origin the outline was serialized from; travels with it for labeling. */
  origin: string;
  elements: OutlineElement[];
}

/** The planner-side description of the element it wants to act on. */
export interface ElementQuery {
  role?: string;
  name?: string;
  /** Substring expected inside the element's value or visible text. */
  text?: string;
}

/** Comparison form: trimmed and case-folded; undefined folds to "". */
function norm(value: string | undefined): string {
  return (value ?? "").trim().toLowerCase();
}

const NAME_TIERS = { exact: 40, prefix: 24, contains: 12 };
const TEXT_TIERS = { exact: 20, prefix: 12, contains: 6 };
const ROLE_MATCH = 10;
const ROLE_MISMATCH = -100;

/**
 * Tiered phrase score with caller-chosen weights: an empty side scores 0, then
 * exact beats prefix beats substring. One helper serves both the
 * accessible-name and the free-text comparisons so the tiers stay in lockstep.
 */
function phraseScore(
  query: string,
  target: string,
  tiers: { exact: number; prefix: number; contains: number },
): number {
  if (query === "" || target === "") return 0;
  if (target === query) return tiers.exact;
  if (target.startsWith(query)) return tiers.prefix;
  if (target.includes(query)) return tiers.contains;
  return 0;
}

/**
 * Pick the selector for `query` out of the outline. The query's role must
 * match when given (a mismatch disqualifies the element outright); the
 * accessible name and the free-text signal add weighted points. Elements
 * scoring zero or less are never candidates, an empty-selector outline entry
 * is never a candidate (querySelector("") would throw), and undefined comes
 * back when nothing qualifies.
 */
export function groundElement(query: ElementQuery, outline: PageOutline): string | undefined {
  const queryRole = norm(query.role);
  const queryName = norm(query.name);
  const queryText = norm(query.text);
  let best: { selector: string; score: number } | undefined;
  for (const element of outline.elements) {
    if (element.selector === "") continue;
    const roleScore =
      queryRole === "" ? 0 : norm(element.role) === queryRole ? ROLE_MATCH : ROLE_MISMATCH;
    const nameScore = phraseScore(queryName, norm(element.name), NAME_TIERS);
    const targetText = norm(element.text);
    const targetValue = norm(element.value);
    const textScore = Math.max(
      phraseScore(queryText, targetValue, TEXT_TIERS),
      phraseScore(queryText, targetText, TEXT_TIERS),
    );
    const score = roleScore + nameScore + textScore;
    if (score <= 0) continue;
    // Strictly better only: ties keep the earliest element in document order.
    if (best === undefined || score > best.score) best = { selector: element.selector, score };
  }
  return best?.selector;
}
