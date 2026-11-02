import { collections } from "./collections";
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { z } from "zod";
export interface Database {
  query(
    text: string,
    values?: any[],
  ): Promise<{ rows: any[]; rowCount?: number | null }>;
}
const hash = (s: string) => createHash("sha256").update(s).digest("hex");
const envelope = z
  .string()
  .min(40)
  .max(90000)
  .regex(/^[A-Za-z0-9+/]+={0,2}$/);
const recordKey = z.enum([
  "theme",
  "showApplicationIcons",
  "reduceMotion",
  "backgroundOpacity",
  "backgroundBlur",
]);
const record = z
  .object({
    key: recordKey,
    revision: z.number().int().min(0).max(2147483646),
    ciphertext: envelope,
  })
  .strict();
const pair = z
  .object({
    name: z.string().trim().min(1).max(80),
    platform: z.enum(["mac", "android"]),
  })
  .strict();
const clip = z.object({ id: z.string().uuid(), ciphertext: envelope }).strict();
const json = (value: unknown, status = 200) =>
  Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
class HTTPError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
async function body(request: Request, maximum = 100000) {
  if (!request.headers.get("content-type")?.startsWith("application/json"))
    throw new HTTPError(415, "Expected JSON");
  const reader = request.body?.getReader();
  if (!reader) throw new HTTPError(400, "Missing body");
  let size = 0;
  const parts: Uint8Array[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > maximum) {
      await reader.cancel();
      throw new HTTPError(413, "Request too large");
    }
    parts.push(value);
  }
  return JSON.parse(Buffer.concat(parts).toString("utf8"));
}
export function createHandler(
  db: Database,
  config: { pairingSecret: string; owner: string },
) {
  // Bounded, per-process abuse control. Reverse proxy should also rate-limit public traffic.
  const buckets = new Map<string, { start: number; count: number }>();
  function limit(key: string, max: number) {
    const now = Date.now();
    let b = buckets.get(key);
    if (!b || now - b.start > 60000) {
      b = { start: now, count: 0 };
      if (buckets.size > 4096) buckets.clear();
      buckets.set(key, b);
    }
    if (++b.count > max) throw new HTTPError(429, "Try again later");
  }
  return async (request: Request): Promise<Response> => {
    try {
      const url = new URL(request.url),
        path = url.pathname.replace(/^\/api\/v1/, "");
      const method = request.method;
      limit("requests", 6000);
      if (path === "/health" && method === "GET") {
        await db.query("SELECT 1");
        return json({ ok: true, version: 1 });
      }
      const token =
        request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
      if (token.length > 256) throw new HTTPError(401, "Invalid token");
      if (path === "/pair" && method === "POST") {
        limit("pair", 20);
        if (config.pairingSecret.length < 32)
          throw new HTTPError(503, "Pairing is not configured");
        if (
          !timingSafeEqual(
            Buffer.from(hash(token)),
            Buffer.from(hash(config.pairingSecret)),
          )
        )
          throw new HTTPError(401, "Invalid connection code");
        const data = pair.parse(await body(request));
        const id = randomUUID(),
          secret = randomBytes(32).toString("base64url");
        const count = await db.query(
          "SELECT count(*) AS n FROM devices WHERE owner=$1 AND revoked IS NULL",
          [config.owner],
        );
        if (Number(count.rows[0].n) >= 32)
          throw new HTTPError(409, "Device limit reached");
        await db.query(
          "INSERT INTO devices(id,owner,name,platform,token_hash) VALUES($1,$2,$3,$4,$5)",
          [id, config.owner, data.name, data.platform, hash(secret)],
        );
        return json({ id, token: secret, owner: config.owner }, 201);
      }
      const found = await db.query(
        "SELECT id,owner,name,platform FROM devices WHERE token_hash=$1 AND revoked IS NULL",
        [hash(token)],
      );
      const device = found.rows[0];
      if (!device) throw new HTTPError(401, "Device disconnected");
      limit(device.id, 120);
      if (path === "/collections" || path.startsWith("/collections/")) {
        const response = await collections(db, request, device, () => body(request, 2100000));
        response.headers.set("Cache-Control", "no-store");
        return response;
      }
      if (path === "/devices" && method === "GET")
        return json({
          devices: (
            await db.query(
              "SELECT id,name,platform FROM devices WHERE owner=$1 AND revoked IS NULL ORDER BY name",
              [device.owner],
            )
          ).rows,
        });
      if (path.startsWith("/devices/") && method === "DELETE") {
        const id = z.string().uuid().parse(path.slice(9));
        await db.query(
          "UPDATE devices SET revoked=now() WHERE owner=$1 AND id=$2",
          [device.owner, id],
        );
        return json({ ok: true });
      }
      if (path === "/settings" && method === "GET")
        return json({
          records: (
            await db.query(
              'SELECT key,revision,ciphertext,device_id AS "deviceId" FROM records WHERE owner=$1 ORDER BY key',
              [device.owner],
            )
          ).rows,
        });
      if (path === "/settings" && method === "POST") {
        const data = record.parse(await body(request));
        const result = await db.query(
          `INSERT INTO records(owner,key,revision,ciphertext,device_id)
 SELECT $1,$2,1,$3,$4 WHERE $5::integer=0
 ON CONFLICT(owner,key) DO NOTHING RETURNING revision`,
          [device.owner, data.key, data.ciphertext, device.id, data.revision],
        );
        if (result.rows.length) return json(result.rows[0]);
        const updated = await db.query(
          "UPDATE records SET revision=revision+1,ciphertext=$3,device_id=$4,updated=now() WHERE owner=$1 AND key=$2 AND revision=$5 RETURNING revision",
          [device.owner, data.key, data.ciphertext, device.id, data.revision],
        );
        if (!updated.rows.length)
          throw new HTTPError(
            409,
            "Setting changed on another device. Refresh before choosing a version.",
          );
        return json(updated.rows[0]);
      }
      if (path === "/clips" && method === "GET") {
        await db.query(
          "DELETE FROM clips WHERE owner=$1 AND created<=now()-interval '24 hours'",
          [device.owner],
        );
        const ids = await db.query(
          "SELECT id FROM clips WHERE owner=$1 AND created>now()-interval '24 hours' ORDER BY created DESC,id DESC LIMIT 50",
          [device.owner],
        );
        const etag = '"' + hash(JSON.stringify(ids.rows)) + '"';
        if (request.headers.get("if-none-match") === etag)
          return new Response(null, {
            status: 304,
            headers: { ETag: etag, "Cache-Control": "private, no-cache" },
          });
        const response = json({
          clips: (
            await db.query(
              'SELECT id,device_id AS "deviceId",ciphertext FROM clips WHERE owner=$1 AND id=ANY($2::text[]) ORDER BY created DESC,id DESC',
              [device.owner, ids.rows.map((r) => r.id)],
            )
          ).rows,
        });
        response.headers.set("ETag", etag);
        return response;
      }
      if (path === "/clips" && method === "POST") {
        const data = clip.parse(await body(request));
        await db.query(
          "DELETE FROM clips WHERE owner=$1 AND created<=now()-interval '24 hours'",
          [device.owner],
        );
        await db.query(
          "INSERT INTO clips(owner,id,device_id,ciphertext) VALUES($1,$2,$3,$4) ON CONFLICT(owner,id) DO NOTHING",
          [device.owner, data.id, device.id, data.ciphertext],
        );
        // Bounded storage, even when devices generate a large number of clips.
        await db.query(
          "DELETE FROM clips WHERE owner=$1 AND id NOT IN (SELECT id FROM clips WHERE owner=$1 ORDER BY created DESC,id DESC LIMIT 100)",
          [device.owner],
        );
        return json({ ok: true });
      }
      if (path === "/clips" && method === "DELETE") {
        await db.query("DELETE FROM clips WHERE owner=$1", [device.owner]);
        return json({ ok: true });
      }
      throw new HTTPError(404, "Unknown endpoint");
    } catch (error) {
      if (error instanceof HTTPError)
        return json({ error: error.message }, error.status);
      if (error instanceof z.ZodError || error instanceof SyntaxError)
        return json({ error: "Invalid request" }, 400);
      return json({ error: "Server unavailable" }, 503);
    }
  };
}
