/**
 * Minimal ambient typing for the jsdom dev dependency (only what the corpus
 * suite uses: parse an HTML string with a fixed URL). Keeps the repo free of
 * a @types package; jsdom itself stays a devDependency of the test rig.
 */
declare module "jsdom" {
  export interface JSDOMOptions {
    url?: string | undefined;
  }

  export class JSDOM {
    constructor(html?: string, options?: JSDOMOptions);
    readonly window: Window & typeof globalThis;
  }
}
