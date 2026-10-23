import type { PageRecord, TranscriptRecord } from "./store";

/**
 * Keyword search over the local history datasets: chat transcripts and
 * chrome.history-style page records. Pure and synchronous so it is fully
 * branch-testable; the store-backed entry (searchStoredHistory) just loads
 * both datasets and delegates here.
 *
 * Matching is case-insensitive substring over title, url and message text.
 * Scoring is deliberately simple (weights documented on the constants below);
 * hits sort by score, then newest first.
 */

/** Weight for one keyword found in a record's title. */
const TITLE_WEIGHT = 3;
/** Weight for one keyword found in a page url. */
const URL_WEIGHT = 1;
/** Weight for one keyword found in one transcript message. */
const MESSAGE_WEIGHT = 2;
/** Recency bonus for records touched within the last 7 / 30 days. */
const FRESH_DAYS = 7;
const RECENT_DAYS = 30;
const FRESH_BONUS = 2;
const RECENT_BONUS = 1;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Result cap when the query does not name one. */
export const DEFAULT_SEARCH_LIMIT = 50;

export interface HistoryQuery {
  /** All keywords must match somewhere (AND); empty means match everything. */
  keywords: string[];
  /** Inclusive lower bound on the record's date (epoch ms). */
  since?: number;
  /** Inclusive upper bound on the record's date (epoch ms). */
  until?: number;
  /** Maximum hits returned, best first. */
  limit?: number;
}

/** One search result, normalized across the two dataset kinds. */
export interface SearchHit {
  kind: "page" | "transcript";
  /** Page url, or transcript id. */
  id: string;
  title: string;
  /** Page url; transcripts have none and carry "". */
  url: string;
  /** Page lastVisitTime, or transcript updatedAt (epoch ms). */
  date: number;
  score: number;
}

function normalizeKeywords(keywords: string[]): string[] {
  return keywords
    .map((keyword) => keyword.trim().toLowerCase())
    .filter((keyword) => keyword !== "");
}

/** AND semantics: every keyword must score somewhere, else the record drops. */
function scorePage(page: PageRecord, terms: string[]): number | null {
  const title = page.title.toLowerCase();
  const url = page.url.toLowerCase();
  let score = 0;
  for (const term of terms) {
    let termScore = 0;
    if (title.includes(term)) termScore += TITLE_WEIGHT;
    if (url.includes(term)) termScore += URL_WEIGHT;
    if (termScore === 0) return null;
    score += termScore;
  }
  return score;
}

/** Same AND semantics, matching against the title and every message text. */
function scoreTranscript(transcript: TranscriptRecord, terms: string[]): number | null {
  const title = transcript.title.toLowerCase();
  let score = 0;
  for (const term of terms) {
    let termScore = title.includes(term) ? TITLE_WEIGHT : 0;
    for (const message of transcript.messages) {
      if (message.text.toLowerCase().includes(term)) termScore += MESSAGE_WEIGHT;
    }
    if (termScore === 0) return null;
    score += termScore;
  }
  return score;
}

function recencyBonus(date: number, now: number): number {
  const age = Math.max(0, now - date);
  if (age <= FRESH_DAYS * DAY_MS) return FRESH_BONUS;
  if (age <= RECENT_DAYS * DAY_MS) return RECENT_BONUS;
  return 0;
}

function inRange(date: number, query: HistoryQuery): boolean {
  if (query.since !== undefined && date < query.since) return false;
  if (query.until !== undefined && date > query.until) return false;
  return true;
}

/**
 * Search both datasets. `now` is injected so recency scoring is deterministic
 * under test; callers pass Date.now(). An empty (or all-blank) keyword list
 * matches every in-range record, which is the browse-recent mode.
 */
export function searchHistory(
  pages: PageRecord[],
  transcripts: TranscriptRecord[],
  query: HistoryQuery,
  now: number,
): SearchHit[] {
  const terms = normalizeKeywords(query.keywords);
  const hits: SearchHit[] = [];
  for (const page of pages) {
    if (!inRange(page.lastVisitTime, query)) continue;
    const base = scorePage(page, terms);
    if (base === null) continue;
    hits.push({
      kind: "page",
      id: page.url,
      title: page.title,
      url: page.url,
      date: page.lastVisitTime,
      score: base + recencyBonus(page.lastVisitTime, now),
    });
  }
  for (const transcript of transcripts) {
    if (!inRange(transcript.updatedAt, query)) continue;
    const base = scoreTranscript(transcript, terms);
    if (base === null) continue;
    hits.push({
      kind: "transcript",
      id: transcript.id,
      title: transcript.title,
      url: "",
      date: transcript.updatedAt,
      score: base + recencyBonus(transcript.updatedAt, now),
    });
  }
  hits.sort((a, b) => b.score - a.score || b.date - a.date);
  return hits.slice(0, Math.max(0, query.limit ?? DEFAULT_SEARCH_LIMIT));
}

/** Store-backed convenience: load both datasets, then run the pure search. */
export async function searchStoredHistory(
  store: {
    allPages(): Promise<PageRecord[]>;
    allTranscripts(): Promise<TranscriptRecord[]>;
  },
  query: HistoryQuery,
  now: number = Date.now(),
): Promise<SearchHit[]> {
  const [pages, transcripts] = await Promise.all([store.allPages(), store.allTranscripts()]);
  return searchHistory(pages, transcripts, query, now);
}
