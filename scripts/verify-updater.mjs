import { createHash, createPublicKey, verify } from "node:crypto";

// Tauri wraps the Minisign public key and signature text in base64. Verify both
// the archive and trusted comment, using Node's Ed25519 implementation.
export function verifyUpdater(bytes, encodedSignature, encodedKey) {
  const keyLines = Buffer.from(encodedKey.trim(), "base64").toString("utf8").trim().split(/\r?\n/);
  const lines = Buffer.from(encodedSignature.trim(), "base64").toString("utf8").trim().split(/\r?\n/);
  const key = Buffer.from(keyLines[1] ?? "", "base64");
  const packet = Buffer.from(lines[1] ?? "", "base64");
  const global = Buffer.from(lines[3] ?? "", "base64");
  if (key.length !== 42 || packet.length !== 74 || global.length !== 64 ||
      key.subarray(0, 2).toString() !== "Ed" || packet.subarray(0, 2).toString() !== "ED" ||
      !key.subarray(2, 10).equals(packet.subarray(2, 10)) || !lines[2]?.startsWith("trusted comment: ")) {
    throw new Error("Invalid updater signature or public key.");
  }
  const publicKey = createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), key.subarray(10)]),
    format: "der", type: "spki",
  });
  const signature = packet.subarray(10);
  const hash = createHash("blake2b512").update(bytes).digest();
  const comment = Buffer.from(lines[2].slice("trusted comment: ".length));
  if (!verify(null, hash, publicKey, signature) ||
      !verify(null, Buffer.concat([signature, comment]), publicKey, global)) {
    throw new Error("Updater archive signature verification failed.");
  }
}
