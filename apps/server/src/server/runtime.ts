import { Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import * as schema from "./schema";
import { createHandler } from "./service";
const pool = new Pool({
  connectionString: process.env.DATABASE_URL || "postgres://invalid:invalid@127.0.0.1:1/unconfigured",
  max: 3,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});
export const db = drizzle(pool, { schema });
const configuredHandler = createHandler(pool, {
  pairingSecret: process.env.PRISM_PAIRING_SECRET ?? "",
  owner: process.env.PRISM_OWNER_ID ?? "personal",
});

export const handle = (request: Request) => process.env.DATABASE_URL ? configuredHandler(request) : Promise.resolve(Response.json({error: "Database is not configured"}, {status: 503}));
