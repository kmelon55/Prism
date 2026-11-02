import { Pool } from "pg";
import { readFile } from "node:fs/promises";
if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required");
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
try {
  await pool.query(
    await readFile(
      new URL("../../migrations/0001.sql", import.meta.url),
      "utf8",
    ),
  );
  await pool.query(
    await readFile(
      new URL("../../migrations/0002.sql", import.meta.url),
      "utf8",
    ),
  );
} finally {
  await pool.end();
}
