#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxTerminal, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/omfx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-term-session-resume.mjs");
  process.exit(2);
}

const wasm = await readFile(wasmPath);
const encoded = new TextEncoder();
let fetchCalls = 0;
const mockFetch = async () => {
  fetchCalls += 1;
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","id":"answer","delta":"ZXQJ"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const records = new Map();
let nextRevision = 1;
let commits = 0;
const sessionStore = {
  load(id) {
    const record = records.get(id);
    return record ? { bytes: record.bytes.slice(), revision: record.revision } : null;
  },
  commit(id, bytes, expectedRevision) {
    const current = records.get(id);
    if (current?.revision !== expectedRevision) {
      const error = new Error("session revision conflict");
      error.code = "FX_SESSION_REVISION_CONFLICT";
      throw error;
    }
    const revision = String(nextRevision++);
    records.set(id, { bytes: bytes.slice(), revision, updatedAtMs: Date.now() });
    commits += 1;
    return { revision };
  },
  list() {
    return [...records.entries()].map(([id, record]) => ({
      id,
      updatedAtMs: record.updatedAtMs,
    }));
  },
  remove(id) {
    records.delete(id);
  },
};

function createTerminalCapture() {
  const decoder = new TextDecoder();
  let text = "";
  return {
    terminal: {
      cols: 80,
      rows: 24,
      write(value) {
        const bytes = value instanceof Uint8Array ? value : encoded.encode(value);
        text += decoder.decode(bytes, { stream: true });
      },
      async drain() {},
      onData() { return () => {}; },
      onResize() { return () => {}; },
    },
    text() { return text; },
  };
}

async function waitFor(predicate, label, diagnostics = () => "") {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() >= deadline) {
      throw new Error(`timed out waiting for ${label}: ${diagnostics()}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function start(args = []) {
  const capture = createTerminalCapture();
  const runtime = await createFxTerminal({
  backend: "wasm",
    wasm,
    args,
    terminal: capture.terminal,
    env: { AI_GATEWAY_API_KEY: "term-session-test-key", FX_THEME: "dark" },
    fetch: mockFetch,
    sessionStore,
  });
  await waitFor(
    () => capture.text().includes(args.length ? "Session resumed" : "Run /help for commands"),
    "fx-term startup",
    () => `output=${JSON.stringify(capture.text().slice(-1000))}`,
  );
  return { capture, runtime };
}

async function exit(runtime, label) {
  runtime.write("/exit\r");
  const exitCode = await Promise.race([
    runtime.exited,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out waiting for ${label} exit`)), 5000)),
  ]);
  if (exitCode !== 0) throw new Error(`${label} exited with code ${exitCode}`);
}

const first = await start();
first.runtime.write("remember this browser turn\r");
await waitFor(
  () => fetchCalls === 1,
  "gateway response",
  () => `commits=${commits}, fetches=${fetchCalls}, output=${JSON.stringify(first.capture.text().slice(-1000))}`,
);
await waitFor(
  () => commits === 1,
  "completed-turn session commit",
  () => `commits=${commits}, fetches=${fetchCalls}, output=${JSON.stringify(first.capture.text().slice(-1000))}`,
);
await exit(first.runtime, "first terminal");

const second = await start(["--resume", "last"]);
const restoredBeforeInput = second.capture.text();
if (!restoredBeforeInput.includes("remember this browser turn")) {
  throw new Error("second terminal did not replay the restored user prompt before input");
}
if (!restoredBeforeInput.includes("ZXQJ")) {
  throw new Error("second terminal did not replay the restored assistant reply before input");
}
if (fetchCalls !== 1) throw new Error("restore triggered an unexpected gateway request");
await exit(second.runtime, "second terminal");

console.log(`term session resume passed: commits=${commits}, records=${records.size}, restored_prompt=true, restored_reply=true`);
