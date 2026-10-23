import http from "node:http";
import type { AddressInfo } from "node:net";

export interface FixtureServer {
  url: string;
  close(): Promise<void>;
  /** Captured request bodies (scripted mode only), one JSON string per request. */
  bodies: string[];
}

export interface FixtureVariant {
  /** OpenAI wire stream ends without [DONE] (and includes odd payloads). */
  openaiUndone?: boolean;
  /** Anthropic wire stream ends without message_stop. */
  anthropicUndone?: boolean;
  /** OpenAI wire stream's last event is a data payload with no trailing newline. */
  openaiTail?: boolean;
  /** Anthropic wire stream's last event is a text delta with no trailing newline. */
  anthropicTail?: boolean;
  /**
   * Scripted OpenAI wire turns: one entry per request, each a list of text
   * deltas streamed back in order. Later requests replay the last entry.
   * Requests are auth-checked like the default route and their bodies land
   * in `bodies` so tests can assert prompt construction.
   */
  openaiScript?: string[][];
}

/**
 * Minimal fixture speaking both wires, so provider tests run against real HTTP
 * and real SSE parsing without any network dependency (Gate 1 rule: fixture
 * servers for both wire protocols, not just the fleet default). Variants make
 * streams end without their terminator so client tail handling is exercised.
 */
export async function startFixtureServer(variant: FixtureVariant = {}): Promise<FixtureServer> {
  const script = variant.openaiScript ?? [];
  let turn = 0;
  const bodies: string[] = [];
  const server = http.createServer((req, res) => {
    const url = req.url ?? "";
    if (url.endsWith("/chat/completions") && script.length > 0) {
      const chunks: string[] = [];
      req.on("data", (piece: Buffer) => chunks.push(piece.toString()));
      req.on("end", () => {
        bodies.push(chunks.join(""));
        if (req.headers.authorization !== "Bearer test-key") {
          res.writeHead(401, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "bad key" }));
          return;
        }
        const deltas = script[Math.min(turn, script.length - 1)];
        turn += 1;
        res.writeHead(200, { "content-type": "text/event-stream" });
        for (const delta of deltas) {
          res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: delta } }] })}\n\n`);
        }
        res.write("data: [DONE]\n\n");
        res.end();
      });
      return;
    }
    if (url.endsWith("/chat/completions")) {
      if (variant.openaiTail) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "A" } }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "B" } }] })}`);
        res.end();
        return;
      }
      if (variant.openaiUndone) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "A" } }] })}\n\n`);
        res.write("data:\n\n");
        res.write(`data: ${JSON.stringify({ choices: [{ delta: {} }] })}\n\n`);
        res.write(`data: ${JSON.stringify({})}\n\n`);
        res.write(`data: ${JSON.stringify({ choices: [] })}\n\n`);
        res.write("data: [DONE]");
        res.end();
        return;
      }
      if (req.headers.authorization !== "Bearer test-key") {
        res.writeHead(401, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "bad key" }));
        return;
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "Hel" } }] })}\n\n`);
      res.write(": keep-alive comment\n\n");
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: "lo" } }] })}\r\n\r\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ delta: {} }] })}\n\n`);
      res.write("data: [DONE]\n\n");
      res.end();
      return;
    }
    if (url.endsWith("/messages")) {
      if (variant.anthropicTail) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", delta: { text: "Y" } })}`);
        res.end();
        return;
      }
      if (variant.anthropicUndone) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", delta: { text: "X" } })}\n\n`);
        res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", delta: {} })}\n\n`);
        res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta" })}\n\n`);
        res.write("event: ping\ndata:\n\n");
        res.write(`event: message_stop\ndata: ${JSON.stringify({ type: "message_stop" })}`);
        res.end();
        return;
      }
      if (req.headers["x-api-key"] !== "test-key") {
        res.writeHead(401, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "bad key" }));
        return;
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", delta: { text: "wor" } })}\n\n`);
      res.write(`event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", delta: { text: "ld" } })}\n\n`);
      res.write(`event: message_stop\ndata: ${JSON.stringify({ type: "message_stop" })}\n\n`);
      res.end();
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
    bodies,
  };
}
