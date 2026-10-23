export interface CorpusDirective {
  name: string;
  args: Record<string, unknown>;
}

export interface CorpusEntry {
  file: string;
  category: string;
  origin: string;
  html: string;
  directive: CorpusDirective;
  mustContain: string;
}

export declare const SENTINEL_START: string;
export declare const SENTINEL_END: string;
export declare function buildCorpus(): CorpusEntry[];
