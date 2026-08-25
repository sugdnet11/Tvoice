import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request(`http://localhost${path}`, { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the Tvoice PWA shell", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /<title>Tvoice — звонки и сообщения<\/title>/i);
  assert.match(html, /manifest\.webmanifest/i);
  assert.match(html, /tvoice-icon\.png/i);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape/i);
});

test("exposes runtime connection configuration without secrets", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("config", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  const response = await worker.fetch(
    new Request("http://localhost/api/config"),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
  assert.equal(response.status, 200);
  const config = await response.json();
  assert.match(config.wsUrl, /^wss:\/\//);
  assert.equal(Object.hasOwn(config, "password"), false);
  assert.equal(Object.hasOwn(config, "livekitSecret"), false);
});

test("guest conference routes do not duplicate the API version prefix", async () => {
  const source = await readFile(
    new URL("../app/conference/join/[token]/GuestConference.tsx", import.meta.url),
    "utf8",
  );
  assert.doesNotMatch(source, /\/api\/tvoice\/v1\//);
  assert.match(source, /\/api\/tvoice\/conferences\/invitations\//);
});

test("guest conference keeps the video grid inside one viewport", async () => {
  const [source, styles] = await Promise.all([
    readFile(
      new URL("../app/conference/join/[token]/GuestConference.tsx", import.meta.url),
      "utf8",
    ),
    readFile(
      new URL("../app/conference/join/[token]/guest-conference.css", import.meta.url),
      "utf8",
    ),
  ]);
  assert.match(styles, /height:\s*100dvh/);
  assert.match(styles, /\.guest-room[\s\S]*overflow:\s*hidden/);
  assert.match(styles, /\.guest-room-body[\s\S]*min-height:\s*0/);
  assert.match(styles, /\.guest-chat\.is-open/);
  assert.match(source, /chatOpen/);
  assert.match(source, /aria-label="Чат"/);
});

test("guest conference renders and unlocks remote audio", async () => {
  const source = await readFile(
    new URL("../app/conference/join/[token]/GuestConference.tsx", import.meta.url),
    "utf8",
  );
  assert.match(source, /audioTrackPublications/);
  assert.match(source, /track\.attach\(\)/);
  assert.match(source, /room\.startAudio\(\)/);
  assert.match(source, /AudioPlaybackStatusChanged/);
  assert.match(source, /Включить звук/);
});
