import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
import { createHandler } from "../src/server/service";
const db = new PGlite();
const code = "test-only-connection-secret-32-characters";
const api = createHandler(db, { pairingSecret: code, owner: "alice" });
const other = createHandler(db, { pairingSecret: code, owner: "bob" });
const cipher = Buffer.alloc(32, 7).toString("base64");
const req = (path: string, token: string, method = "GET", body?: unknown) =>
  new Request("https://sync.example/api/v1/" + path, {
    method,
    headers: {
      authorization: "Bearer " + token,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
async function register(handler = api) {
  const response = await handler(
    req("pair", code, "POST", { name: "Test Mac", platform: "mac" }),
  );
  assert.equal(response.status, 201);
  return (await response.json()) as { id: string; token: string };
}
let a: { id: string; token: string },
  b: { id: string; token: string },
  outsider: { id: string; token: string };
before(async () => {
  await db.exec(
    await readFile(new URL("../migrations/0001.sql", import.meta.url), "utf8"),
  );
  await db.exec(
    await readFile(new URL("../migrations/0002.sql", import.meta.url), "utf8"),
  );
  a = await register();
  b = await register();
  outsider = await register(other);
});
after(() => db.close());
test("pairing requires server secret and strict body", async () => {
  assert.equal(
    (await api(req("pair", "wrong", "POST", { name: "Mac", platform: "mac" })))
      .status,
    401,
  );
  assert.equal(
    (
      await api(
        req("pair", code, "POST", {
          name: "Mac",
          platform: "mac",
          owner: "bob",
        }),
      )
    ).status,
    400,
  );
  assert.equal((await api(req("settings", "wrong"))).status, 401);
});
test("settings compare-and-swap preserves concurrent edits", async () => {
  assert.equal(
    (
      await api(
        req("settings", a.token, "POST", {
          key: "theme",
          revision: 0,
          ciphertext: cipher,
        }),
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await api(
        req("settings", b.token, "POST", {
          key: "theme",
          revision: 0,
          ciphertext: cipher,
        }),
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await api(
        req("settings", b.token, "POST", {
          key: "theme",
          revision: 1,
          ciphertext: cipher,
        }),
      )
    ).status,
    200,
  );
  const result = await (await api(req("settings", a.token))).json();
  assert.equal(result.records[0].revision, 2);
});
test("unknown settings and plaintext are rejected", async () => {
  assert.equal(
    (
      await api(
        req("settings", a.token, "POST", {
          key: "apiKey",
          revision: 0,
          ciphertext: cipher,
        }),
      )
    ).status,
    400,
  );
  assert.equal(
    (
      await api(
        req("clips", a.token, "POST", {
          id: randomUUID(),
          ciphertext: "plaintext",
        }),
      )
    ).status,
    400,
  );
});
test("tenant data and revocation are isolated", async () => {
  const result = await (await other(req("settings", outsider.token))).json();
  assert.deepEqual(result.records, []);
  await other(req("devices/" + a.id, outsider.token, "DELETE"));
  assert.equal((await api(req("settings", a.token))).status, 200);
  const listed = await (await other(req("devices", outsider.token))).json();
  assert.equal(listed.devices.length, 1);
});
test("retrying an upload does not duplicate content", async () => {
  const id = randomUUID();
  for (let i = 0; i < 2; i++)
    assert.equal(
      (await api(req("clips", a.token, "POST", { id, ciphertext: cipher })))
        .status,
      200,
    );
  const result = await (await api(req("clips", b.token))).json();
  assert.equal(result.clips.length, 1);
  assert.equal(result.clips[0].deviceId, a.id);
  const isolated = await (await other(req("clips", outsider.token))).json();
  assert.equal(isolated.clips.length, 0);
});
test("expired clips are not delivered", async () => {
  await db.query(
    "UPDATE clips SET created=now()-interval '25 hours' WHERE owner='alice'",
  );
  const result = await (await api(req("clips", b.token))).json();
  assert.equal(result.clips.length, 0);
});
test("device revocation invalidates token immediately", async () => {
  await api(req("devices/" + b.id, a.token, "DELETE"));
  assert.equal((await api(req("clips", b.token))).status, 401);
});
test("body size is bounded without Content-Length", async () => {
  const response = await api(
    req("clips", a.token, "POST", {
      id: randomUUID(),
      ciphertext: "a".repeat(110000),
    }),
  );
  assert.equal(response.status, 413);
});
test("unchanged clipboard avoids retransmitting ciphertext", async () => {
  const first = await api(req("clips", a.token));
  const tag = first.headers.get("etag");
  assert.ok(tag);
  const request = req("clips", a.token);
  request.headers.set("if-none-match", tag!);
  const unchanged = await api(request);
  assert.equal(unchanged.status, 304);
  assert.equal(await unchanged.text(), "");
});

test("device profiles are isolated, selectable and compare-and-swap protected", async () => {
  const own = `collections/notes?source=${a.id}`;
  assert.equal(
    (await api(req(own, a.token, "POST", { revision: 0, ciphertext: cipher })))
      .status,
    200,
  );
  assert.equal(
    (await api(req(own, a.token, "POST", { revision: 0, ciphertext: cipher })))
      .status,
    409,
  );
  const fresh = await register();
  assert.equal(
    (
      await api(
        req(own, fresh.token, "POST", { revision: 1, ciphertext: cipher }),
      )
    ).status,
    403,
  );
  const read = await (await api(req(own, fresh.token))).json();
  assert.equal(read.record.revision, 1);
  const isolated = await (await other(req(own, outsider.token))).json();
  assert.equal(isolated.record, null);
  const shared = await (await api(req("collections/notes", a.token))).json();
  assert.equal(shared.record, null);
  const listing = await (
    await api(req(`collections?source=${a.id}`, a.token))
  ).json();
  assert.equal(listing.records.length, 1);
  assert.equal(listing.records[0].ciphertext, undefined);
});
test("API keys remain opaque and unknown categories cannot be stored", async () => {
  assert.equal(
    (
      await api(
        req("collections/key.openai", a.token, "POST", {
          revision: 0,
          ciphertext: cipher,
        }),
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await api(
        req("collections/key.sync-token", a.token, "POST", {
          revision: 0,
          ciphertext: cipher,
        }),
      )
    ).status,
    400,
  );
  assert.equal(
    (
      await api(
        req("collections/key.openai", a.token, "POST", {
          revision: 1,
          ciphertext: "secret",
        }),
      )
    ).status,
    400,
  );
  const result = await (
    await api(req("collections/key.openai", a.token))
  ).json();
  assert.equal(result.record.ciphertext, cipher);
});
