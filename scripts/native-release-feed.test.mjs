import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { archiveName, nativePublicKey, writeChecksums } from "./native-release-feed.mjs";

test("read the updater public key the native app trusts", () => {
  const lines = Buffer.from(nativePublicKey(), "base64").toString("utf8").split("\n");
  assert.match(lines[0], /^untrusted comment: minisign public key/);
  assert.equal(Buffer.from(lines[1], "base64").length, 42);
});

test("checksum every release file except the checksum list itself", () => {
  const directory = mkdtempSync(join(tmpdir(), "prism-feed-"));
  writeFileSync(join(directory, archiveName("0.2.0")), "archive");
  writeFileSync(join(directory, "SHA256SUMS.txt"), "stale");
  writeChecksums(directory);
  const digest = createHash("sha256").update("archive").digest("hex");
  assert.equal(readFileSync(join(directory, "SHA256SUMS.txt"), "utf8"), `${digest}  Prism_0.2.0_universal.app.tar.gz\n`);
});
