import {
  pgTable,
  text,
  integer,
  timestamp,
  primaryKey,
} from "drizzle-orm/pg-core";
export const devices = pgTable("devices", {
  id: text().primaryKey(),
  owner: text().notNull(),
  name: text().notNull(),
  platform: text().notNull(),
  tokenHash: text("token_hash").notNull().unique(),
  revoked: timestamp({ withTimezone: true }),
});
export const records = pgTable(
  "records",
  {
    owner: text().notNull(),
    key: text().notNull(),
    revision: integer().notNull(),
    ciphertext: text().notNull(),
    deviceId: text("device_id").notNull(),
    updated: timestamp({ withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.owner, t.key] })],
);
export const clips = pgTable(
  "clips",
  {
    owner: text().notNull(),
    id: text().notNull(),
    deviceId: text("device_id").notNull(),
    ciphertext: text().notNull(),
    created: timestamp({ withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.owner, t.id] })],
);

export const collections = pgTable(
  "collections",
  {
    owner: text().notNull(),
    scope: text().notNull(),
    key: text().notNull(),
    revision: integer().notNull(),
    ciphertext: text().notNull(),
    deviceId: text("device_id").notNull(),
    updated: timestamp({ withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.owner, t.scope, t.key] })],
);
