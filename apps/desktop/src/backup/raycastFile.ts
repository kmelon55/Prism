
export const MAX_RAYCAST_BYTES = 20 * 1024 * 1024;
export class RaycastFileError extends Error {
  constructor(public code: "password" | "decrypt" | "invalid" | "version" | "size") { super(code); }
}
const invalid = () => new RaycastFileError("invalid");
export function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
function hex(value: unknown): Uint8Array<ArrayBuffer> {
  if (typeof value !== "string" || value.length > MAX_RAYCAST_BYTES * 2 || value.length % 2 || !/^[\da-f]*$/i.test(value)) throw invalid();
  return Uint8Array.from(value.match(/../g) ?? [], byte => parseInt(byte, 16));
}
async function unzip(bytes: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
  const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip")).getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.length;
      if (size > MAX_RAYCAST_BYTES) throw new RaycastFileError("size");
      chunks.push(chunk.value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  const output = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.length; }
  return output;
}
function json(bytes: Uint8Array): unknown {
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw invalid(); }
}
/** Decode locally. Never persist the password or pass it to a child process. */
export async function decodeRaycastFile(input: Uint8Array<ArrayBuffer>, password?: string): Promise<unknown> {
  if (!input.length || input.length > MAX_RAYCAST_BYTES) throw new RaycastFileError("size");
  let bytes = input;
  const prefix = new TextDecoder().decode(bytes.slice(0, 64)).trimStart();
  if (bytes[0] !== 0x1f && !prefix.startsWith("{") && !prefix.startsWith("[")) {
    if (bytes.length < 32 || bytes.length % 16) throw invalid();
    if (password === undefined) throw new RaycastFileError("password");
    const { sha256 } = await import("@noble/hashes/sha2.js");
    const keyBytes = sha256(new TextEncoder().encode(password));
    try {
      const key = await crypto.subtle.importKey("raw", new Uint8Array(keyBytes), "AES-CBC", false, ["decrypt"]);
      bytes = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-CBC", iv: bytes.slice(0, 16) }, key, bytes.slice(16)));
      if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) throw invalid();
    } catch { throw new RaycastFileError("decrypt"); }
    finally { keyBytes.fill(0); }
  }
  const envelope = json(await unzip(bytes));
  const outer = record(envelope);
  if (!Object.hasOwn(outer, "schemaVersion")) return envelope;
  if (outer.schemaVersion !== 1 && outer.schemaVersion !== 2) throw new RaycastFileError("version");
  let payload = hex(outer.data);
  if (outer.encryption != null) {
    const encryption = record(outer.encryption);
    const iv = hex(encryption.iv), salt = hex(encryption.salt), tag = hex(encryption.authTag);
    if (![12, 16].includes(iv.length) || tag.length !== 16 || salt.length < 8 || salt.length > 64) throw invalid();
    if (password === undefined) throw new RaycastFileError("password");
    const { scryptAsync } = await import("@noble/hashes/scrypt.js");
    const keyBytes = await scryptAsync(new TextEncoder().encode(password), salt, { N: 16384, r: 8, p: 1, dkLen: 32, maxmem: 40 * 1024 * 1024 });
    try {
      const key = await crypto.subtle.importKey("raw", new Uint8Array(keyBytes), "AES-GCM", false, ["decrypt"]);
      const tagged = new Uint8Array(payload.length + tag.length); tagged.set(payload); tagged.set(tag, payload.length);
      payload = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, tagged));
    } catch { throw new RaycastFileError("decrypt"); }
    finally { keyBytes.fill(0); }
  }
  return json(outer.schemaVersion === 2 ? await unzip(payload) : payload);
}
