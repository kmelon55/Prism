import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { verifyUpdater } from "./verify-updater.mjs";

const encode = (value) => Buffer.from(value).toString("base64");
function fixture() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const id = Buffer.from("12345678");
  const bytes = Buffer.from("synthetic update archive");
  const signature = sign(null, createHash("blake2b512").update(bytes).digest(), privateKey);
  const comment = "timestamp:1234\tfile:Prism.app.tar.gz";
  const global = sign(null, Buffer.concat([signature, Buffer.from(comment)]), privateKey);
  const key = encode(`untrusted comment: public key\n${encode(Buffer.concat([Buffer.from("Ed"), id, publicKey.export({ format: "der", type: "spki" }).subarray(-32)]))}\n`);
  const sig = encode(`untrusted comment: signature\n${encode(Buffer.concat([Buffer.from("ED"), id, signature]))}\ntrusted comment: ${comment}\n${encode(global)}\n`);
  return { bytes, key, sig };
}
test("verify Tauri archive and trusted comment; reject corruption and other keys", () => {
  const { bytes, key, sig } = fixture();
  assert.doesNotThrow(() => verifyUpdater(bytes, sig, key));
  assert.throws(() => verifyUpdater(Buffer.from("tampered archive"), sig, key));
  assert.throws(() => verifyUpdater(bytes, sig, fixture().key));
  const modified = encode(Buffer.from(sig, "base64").toString().replace("timestamp:1234", "timestamp:9999"));
  assert.throws(() => verifyUpdater(bytes, modified, key));
  assert.throws(() => verifyUpdater(bytes, "invalid", key));
});
