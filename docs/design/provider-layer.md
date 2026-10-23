# Provider layer: plug-and-play AI

Requirement (owner, 2026-10-22): the AI functionality must be plug-and-play the way
hummin does it. Any model backend must be usable without code changes: local models on
the fleet, existing subscriptions, and keyed cloud APIs. No vendor lock, no baked-in
cloud dependency, and the default configuration runs entirely on hardware the user owns.

## Prior art: hummin `packages/ai`

hummin (rennf93/hummin, MIT) already solved this for a coding agent. The facts below come
from its source and are the pattern to reproduce:

- A provider is a factory returning one descriptor:
  `createProvider({ id, name, baseUrl, auth, models, api })`
  (`packages/ai/src/models.ts`, example `packages/ai/src/providers/zai-api.ts`).
- The wire protocol is a swappable `api` field (`openAICompletionsApi()`,
  anthropic, pi-messages). Two billing plans can share everything but the base URL: hummin's
  `zai` (coding-plan quota) and `zai-api` (API credit) differ only in `baseUrl`, per the
  comment in `zai-api.ts`.
- Auth strategies are declared, not coded per provider: env-var API keys
  (`envApiKeyAuth("Z.AI API key", ["ZAI_API_KEY"])`), OAuth credentials for subscription
  plans, none for local endpoints.
- Every provider carries a model catalog (`provider.models.ts` files feeding a generated
  registry): model id, contextWindow, maxTokens, reasoning flag, thinking-level map, input
  types, cost.
- Subscriptions are a first-class provider category, not a hack: `qwen-token-plan`,
  `qwen-token-plan-individual`, `xiaomi-token-plan-{cn,ams,sgp}`, `github-copilot`,
  `openai-codex`, `kimi-coding`, `zai`, `zai-coding-cn` (see
  `packages/ai/src/providers/all.ts`).
- Dynamic endpoints need no catalog entry: the `radius` provider fetches
  `GET /v1/config` (baseUrl + model list) from a gateway at runtime and sanitizes it
  (`packages/ai/src/providers/radius-config.ts`). A `KnownProvider` union admits purely
  dynamic ids.

## Design for colibri-browser

One provider abstraction behind the whole browser AI surface (sidebar chat, page chat,
inline writing, skills, intent classification). Nothing in a feature may assume which
provider or model is bound.

### ProviderConfig (zod-validated, settings file plus UI editor)

```ts
{
  id: string;                    // "local-fleet", "zai-coding", "zai-api", ...
  label: string;
  baseUrl: string;               // http://localhost:9991, https://api.z.ai/api/paas/v4, proxy URLs
  wire: "openai-completions" | "anthropic-messages";
  auth:
    | { type: "none" }           // local endpoints
    | { type: "apiKey"; envVar?: string; headerStyle?: "bearer" | "x-api-key" };
  models: Array<{
    id: string;                  // as the endpoint names it
    label?: string;
    contextWindow: number;       // drives the tab-context budget allocator
    maxTokens?: number;
    reasoning?: boolean;
    default?: boolean;
  }>;
}
```

- **Local fleet ships as the default provider**: `http://localhost:9991` (North, 262K
  context). Fleet entries for other local endpoints are one config line each; discovery
  by `GET /v1/models` merges with manual entries (radius pattern).
- **Existing subscriptions ship as example configs**: coding-plan and API-credit variants
  of the same service differ only in `baseUrl`, exactly like hummin's zai/zai-api pair.
  Endpoints behind a local passthrough proxy (for example a token proxy on :4100 that
  strips replayed thinking) are just another `baseUrl`.
- **Hot-swap**: the sidebar model picker switches provider/model per conversation without
  reload; features re-read the bound model's `contextWindow` and re-budget tab context.
- **Routing** (Phase 3): intent classification runs on a small local model; generation on
  the user-chosen model. Both are entries in the same provider list.

### Security rules

- API keys live in `chrome.storage.local`, never in synced storage, never in the config
  file committed anywhere. Local endpoints need no key at all.
- All provider calls go from the extension service worker directly to the configured
  `baseUrl`. Page content never reaches a provider except through the origin-labeled,
  consent-gated context pipeline (see README security stance).
- Provider responses are untrusted output: they can request tools, but tool execution
  still passes the consent gate; a model can never self-authorize a side effect.

### Phasing

- **Phase 1**: `openai-completions` and `anthropic-messages` wire clients with streaming,
  the config schema above, `/v1/models` discovery for local endpoints, picker UI, fleet
  defaults. Contract tests per wire protocol against fixture servers, 100% line and branch
  coverage on the provider layer.
- **Phase 3**: OAuth flows for subscription providers, routing table (classifier +
  generation), cost/quota display per provider.

## Gate tie-in

Gate 1 includes the provider layer in its coverage and e2e gates: at least one test run
must bind a fixture OpenAI-compatible server and a fixture anthropic-wire server, not just
the fleet default, proving plug-and-play is real and not a hardcoded path.
