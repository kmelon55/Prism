import { z } from "zod";
import type { Database } from "./service";
export const category = z.enum([
  "theme",
  "showApplicationIcons",
  "reduceMotion",
  "backgroundOpacity",
  "backgroundBlur",
  "notes",
  "snippets",
  "links",
  "shortcut.launcher",
  "shortcut.commands",
  "key.openai",
  "key.vercel",
  "key.openrouter",
  "key.dictation-groq",
  "key.dictation-xai",
]);
const payload = z
  .object({
    revision: z.number().int().min(0).max(2147483646),
    ciphertext: z
      .string()
      .min(40)
      .max(2000000)
      .regex(/^[A-Za-z0-9+/]+={0,2}$/),
  })
  .strict();
export async function collections(
  db: Database,
  request: Request,
  device: { id: string; owner: string },
  readBody: () => Promise<unknown>,
) {
  const url = new URL(request.url);
  const source = url.searchParams.get("source") ?? "shared";
  if (source !== "shared" && !z.string().uuid().safeParse(source).success)
    return Response.json({ error: "Invalid source" }, { status: 400 });
  const prefix = "/api/v1/collections";
  if (url.pathname === prefix && request.method === "GET")
    return Response.json({
      records: (
        await db.query(
          'SELECT key,revision,device_id AS "deviceId" FROM collections WHERE owner=$1 AND scope=$2 ORDER BY key',
          [device.owner, source],
        )
      ).rows,
    });
  const key = category.parse(url.pathname.slice(prefix.length + 1));
  if (request.method === "GET") {
    const result = await db.query(
      'SELECT key,revision,ciphertext,device_id AS "deviceId" FROM collections WHERE owner=$1 AND scope=$2 AND key=$3',
      [device.owner, source, key],
    );
    return Response.json({ record: result.rows[0] ?? null });
  }
  if (request.method === "POST") {
    if (source !== "shared" && source !== device.id)
      return Response.json(
        { error: "Cannot write another device profile" },
        { status: 403 },
      );
    const data = payload.parse(await readBody());
    const args = [
      device.owner,
      source,
      key,
      data.ciphertext,
      device.id,
      data.revision,
    ];
    const insert = await db.query(
      "INSERT INTO collections(owner,scope,key,revision,ciphertext,device_id) SELECT $1,$2,$3,1,$4,$5 WHERE $6::integer=0 ON CONFLICT(owner,scope,key) DO NOTHING RETURNING revision",
      args,
    );
    if (insert.rows.length) return Response.json(insert.rows[0]);
    const update = await db.query(
      "UPDATE collections SET revision=revision+1,ciphertext=$4,device_id=$5,updated=now() WHERE owner=$1 AND scope=$2 AND key=$3 AND revision=$6 RETURNING revision",
      args,
    );
    return update.rows.length
      ? Response.json(update.rows[0])
      : Response.json(
          { error: "Collection changed. Refresh before retrying." },
          { status: 409 },
        );
  }
  return Response.json({ error: "Unknown endpoint" }, { status: 404 });
}
