import test from "node:test";
import assert from "node:assert/strict";
import { readUpdaterKey, scryptParameters, signUpdater } from "./sign-updater.mjs";
import { verifyUpdater } from "./verify-updater.mjs";

// A throwaway key made by `tauri signer generate -p "test pass"` for these tests only. It signs nothing real.
const secret = "dW50cnVzdGVkIGNvbW1lbnQ6IHJzaWduIGVuY3J5cHRlZCBzZWNyZXQga2V5ClJXUlRZMEl5cjljYUM3VkozNVRSWUNXajlEeFNZRlhQK0p3OU85Tkd0cno4bkt3bitDOEFBQkFBQUFBQUFBQUFBQUlBQUFBQUhza3FPWFJWem5nOVcvd3VoVUZjZ3I3Z0d6dGdvNjNVMnlUNnRlaUlqSFNXdnIydHVUdWlxbVBpZ1ZNUHBUbDh3eWd5UDRvdWhIRGFMMitPU0ZaaVJBY01TTGJiWmUzSXJwM3kzZ3pzU2J0TWFXUVFWdEZqajRzVzkxd1JSUmRlUVViaVVMaWV1K3c9Cg==";
const pub = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IENDMDU0NDQ0Q0ZDNEU2NTgKUldSWTVzVFBSRVFGek4zSm9hUlZhMXQrL2R6Y1hxa3l4eWVacDBGUHB5WjZDb3RIaEQ0SlhHbngK";

test("sign with a Tauri updater key so the Tauri public key verifies it", () => {
  const bytes = Buffer.from("synthetic update archive");
  const signature = signUpdater(bytes, readUpdaterKey(secret, "test pass"), { fileName: "Prism.app.tar.gz", timestamp: 1234 });
  assert.doesNotThrow(() => verifyUpdater(bytes, signature, pub));
  assert.match(Buffer.from(signature, "base64").toString(), /\ntrusted comment: timestamp:1234\tfile:Prism\.app\.tar\.gz\n/);
  assert.throws(() => verifyUpdater(Buffer.from("tampered archive"), signature, pub));
});

test("reject a wrong password or a malformed key", () => {
  assert.throws(() => readUpdaterKey(secret, "wrong"), /Wrong updater key password/);
  assert.throws(() => readUpdaterKey("invalid", "test pass"), /Invalid updater secret key/);
});

test("pick libsodium scrypt parameters from Minisign limits", () => {
  assert.deepEqual(scryptParameters(1048576n, 33554432n), { N: 32768, r: 8, p: 1 });
  assert.deepEqual(scryptParameters(33554432n, 1073741824n), { N: 1048576, r: 8, p: 1 });
  assert.deepEqual(scryptParameters(1000n, 1073741824n), { N: 1024, r: 8, p: 1 });
});
