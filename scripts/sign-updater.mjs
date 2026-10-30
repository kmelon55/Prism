import { createHash, createPrivateKey, createPublicKey, scryptSync, sign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { basename } from "node:path";

// Signs an updater archive the way `tauri signer sign` does, without the Tauri CLI. The key is the existing
// Tauri updater key: base64 of a Minisign secret key file, optionally encrypted with scrypt. The signature is a
// prehashed Minisign signature (`ED`, BLAKE2b-512) wrapped in base64, which verify-updater.mjs checks.

const ed25519Seed = Buffer.from("302e020100300506032b657004220420", "hex");

/// `encodedKey` is the key text or a path to it, as `TAURI_SIGNING_PRIVATE_KEY` accepts.
export function readUpdaterKey(encodedKey, password = "") {
  const text = existsSync(encodedKey) ? readFileSync(encodedKey, "utf8") : encodedKey;
  const lines = Buffer.from(text.trim(), "base64").toString("utf8").trim().split(/\r?\n/);
  const box = Buffer.from(lines[1] ?? "", "base64");
  if (box.length !== 158 || box.subarray(0, 2).toString() !== "Ed") throw new Error("Invalid updater secret key.");
  const kdf = box.subarray(2, 4).toString("latin1");
  let secret = box.subarray(54, 158);
  if (kdf === "Sc") {
    const salt = box.subarray(6, 38);
    const { N, r, p } = scryptParameters(box.readBigUInt64LE(38), box.readBigUInt64LE(46));
    const stream = scryptSync(Buffer.from(password, "utf8"), salt, secret.length, { N, r, p, maxmem: 256 * N * r });
    secret = Buffer.from(secret.map((byte, index) => byte ^ stream[index]));
  } else if (kdf !== "\0\0") {
    throw new Error(`Unsupported updater key derivation ${JSON.stringify(kdf)}.`);
  }
  const keyID = secret.subarray(0, 8);
  const privateKey = createPrivateKey({ key: Buffer.concat([ed25519Seed, secret.subarray(8, 40)]), format: "der", type: "pkcs8" });
  // The secret holds the seed and its public key; a wrong password breaks the match.
  const publicKey = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32);
  if (!publicKey.equals(secret.subarray(40, 72))) throw new Error("Wrong updater key password.");
  return { keyID, privateKey, publicKey };
}

export function signUpdater(bytes, key, { fileName, timestamp = Math.floor(Date.now() / 1000) } = {}) {
  const signature = sign(null, createHash("blake2b512").update(bytes).digest(), key.privateKey);
  const comment = `timestamp:${timestamp}\tfile:${fileName}`;
  const global = sign(null, Buffer.concat([signature, Buffer.from(comment)]), key.privateKey);
  const text = [
    "untrusted comment: signature from tauri secret key",
    Buffer.concat([Buffer.from("ED"), key.keyID, signature]).toString("base64"),
    `trusted comment: ${comment}`,
    global.toString("base64"),
  ].join("\n") + "\n";
  return Buffer.from(text).toString("base64");
}

export function signUpdaterFile(path, encodedKey, password) {
  return signUpdater(readFileSync(path), readUpdaterKey(encodedKey, password), { fileName: basename(path) });
}

// libsodium's crypto_pwhash_scryptsalsa208sha256 parameter choice, which Minisign keys record as limits.
export function scryptParameters(opslimit, memlimit) {
  const ops = opslimit < 32768n ? 32768n : opslimit;
  const r = 8n;
  let logN = 1n;
  let p = 1n;
  const maxN = ops < memlimit / 32n ? ops / (r * 4n) : memlimit / (r * 128n);
  while (logN < 63n && (1n << logN) <= maxN / 2n) logN += 1n;
  if (ops >= memlimit / 32n) {
    let maxrp = (ops / 4n) / (1n << logN);
    if (maxrp > 0x3fffffffn) maxrp = 0x3fffffffn;
    p = maxrp / r;
  }
  return { N: Number(1n << logN), r: Number(r), p: Number(p) };
}
