import type { CommandItem, CommandProvider } from "@prism/command-core";
import { t } from "../i18n";

export const dateTimeProviderId = "datetime";
export const dateTimeActionIds = { copyResult: "copy-datetime-result" } as const;
const dayMs = 86_400_000;
const minuteMs = 60_000;
const datePattern = "(\\d{4}-\\d{2}-\\d{2})";
const arithmeticPattern = new RegExp(`^${datePattern}\\s*([+-])\\s*(\\d+)\\s*(?:days?|일)$`, "iu");
const relativePattern = new RegExp(`^${datePattern}\\s*(?:에서\\s*)?(\\d+)\\s*일\\s*(후|뒤|전)$`, "u");
const differencePattern = new RegExp(`^${datePattern}\\s*-\\s*${datePattern}$`);
const intervalPattern = new RegExp(`^${datePattern}\\s*(?:to|부터|~|→)\\s*${datePattern}\\s*(?:까지)?\\s*(?:days?|일|차이)?$`, "iu");
const koreanDifferencePattern = new RegExp(`^${datePattern}\\s*(?:와|과)\\s*${datePattern}\\s*(?:날짜\\s*)?차이$`, "u");
const timezonePattern = new RegExp(`^${datePattern}[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?\\s*(Z|[+-]\\d{2}:\\d{2})?(?:\\s*([A-Za-z][A-Za-z0-9_+./-]*|서울|한국))?\\s+(?:to|in|->|→)\\s+([^\\s]+)$`, "iu");

export interface DateTimeCalculation {
  kind: "date" | "difference" | "timezone";
  result: string;
  context: string;
}

function fail(message: string): never { throw new Error(t(message)); }

function dateTimestamp(text: string): number {
  const [year, month, day] = text.split("-").map(Number);
  const value = new Date(0);
  // setUTCFullYear avoids Date.UTC's special interpretation of years 00–99.
  value.setUTCFullYear(year, month - 1, day);
  if (year < 1 || value.getUTCFullYear() !== year || value.getUTCMonth() !== month - 1 || value.getUTCDate() !== day) {
    fail("Invalid calendar date. Use a real date in YYYY-MM-DD format.");
  }
  return value.getTime();
}

function isoDate(timestamp: number): string {
  const value = new Date(timestamp);
  if (!Number.isFinite(timestamp) || value.getUTCFullYear() < 1 || value.getUTCFullYear() > 9999) {
    fail("The result must be between years 0001 and 9999.");
  }
  return value.toISOString().slice(0, 10);
}

function addDays(date: string, amount: string, sign: number): DateTimeCalculation {
  const start = dateTimestamp(date);
  const days = Number(amount);
  if (!Number.isSafeInteger(days) || days > 3_652_058) fail("Use no more than 3,652,058 whole days.");
  return { kind: "date", result: isoDate(start + sign * days * dayMs), context: t("Calendar days · Calculated on this device") };
}

function difference(start: string, end: string): DateTimeCalculation {
  const days = (dateTimestamp(end) - dateTimestamp(start)) / dayMs;
  return { kind: "difference", result: `${days} days`, context: t("{0} → {1} · End date minus start date", { 0: start, 1: end }) };
}

function resolveZone(text: string): string {
  const zone = /^(?:utc|z)$/iu.test(text) ? "UTC" : /^(?:서울|한국)$/u.test(text) ? "Asia/Seoul" : text;
  // Abbreviations such as CST are ambiguous; accept UTC or explicit IANA paths.
  if (zone !== "UTC" && !/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)+$/u.test(zone)) {
    fail("Use UTC or an IANA time zone such as Asia/Seoul or America/New_York.");
  }
  try {
    return new Intl.DateTimeFormat("en-US", { timeZone: zone }).resolvedOptions().timeZone;
  } catch {
    return fail("Unknown time zone. Use an IANA name such as Asia/Seoul.");
  }
}

function formatter(zone: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat("en-US-u-ca-gregory-nu-latn", {
    timeZone: zone, era: "short", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  });
}

function wallTimestamp(format: Intl.DateTimeFormat, timestamp: number): number {
  const parts = Object.fromEntries(format.formatToParts(timestamp).map(({ type, value }) => [type, value]));
  const date = new Date(0);
  const year = parts.era === "BC" ? 1 - Number(parts.year) : Number(parts.year);
  date.setUTCFullYear(year, Number(parts.month) - 1, Number(parts.day));
  date.setUTCHours(Number(parts.hour), Number(parts.minute), Number(parts.second), 0);
  return date.getTime();
}

function offsetMinutes(text: string): number {
  if (/^z$/iu.test(text)) return 0;
  const hours = Number(text.slice(1, 3));
  const minutes = Number(text.slice(4));
  if (hours > 23 || minutes > 59) fail("Invalid UTC offset. Use ±HH:mm with hours below 24 and minutes below 60.");
  return (hours * 60 + minutes) * (text[0] === "-" ? -1 : 1);
}

function localInstant(wall: number, zone: string, explicitOffset?: string): number {
  if (zone === "UTC") {
    if (explicitOffset && offsetMinutes(explicitOffset) !== 0) fail("The UTC offset does not match the source time zone at that local time.");
    return wall;
  }
  const format = formatter(zone);
  if (explicitOffset) {
    const instant = wall - offsetMinutes(explicitOffset) * minuteMs;
    if (wallTimestamp(format, instant) !== wall) fail("The UTC offset does not match the source time zone at that local time.");
    return instant;
  }
  // Modern IANA offsets are whole minutes. Avoid claiming exhaustive resolution
  // for historical local-mean-time offsets with seconds: those need an exact input.
  if (new Date(wall).getUTCFullYear() < 1973) {
    fail("For time-zone dates before 1973, provide an explicit UTC offset or a UTC time.");
  }
  const matches: number[] = [];
  // Enumerate every minute offset, instead of guessing from today's offset or
  // sampling either side of a presumed one-hour DST change. This also detects
  // half-hour transitions and skipped calendar days. No state or result cache.
  for (let offset = -24 * 60; offset <= 24 * 60; offset++) {
    const candidate = wall - offset * minuteMs;
    if (wallTimestamp(format, candidate) === wall) matches.push(candidate);
    if (matches.length > 1) fail("This local time occurs twice because the time-zone offset changes. Add an explicit offset, such as -04:00 or -05:00, to choose the intended time.");
  }
  if (!matches.length) fail("This local time does not exist because the time-zone offset changes. Choose a valid local time or provide an exact UTC time.");
  return matches[0];
}

function zoneResult(timestamp: number, zone: string): string {
  isoDate(timestamp);
  if (zone === "UTC") return new Date(timestamp).toISOString().replace(".000Z", "Z");
  const wall = wallTimestamp(formatter(zone), timestamp);
  isoDate(wall);
  const offset = (wall - timestamp) / 1000;
  const absolute = Math.abs(offset);
  const pad = (value: number) => String(value).padStart(2, "0");
  const suffix = `${offset < 0 ? "-" : "+"}${pad(Math.floor(absolute / 3600))}:${pad(Math.floor(absolute % 3600 / 60))}${absolute % 60 ? `:${pad(absolute % 60)}` : ""}`;
  return `${new Date(wall).toISOString().slice(0, 19)}${suffix}[${zone}]`;
}

/** Explicit, bounded syntax only; unrelated or incomplete queries have no answer. */
export function calculateDateTimeQuery(query: string): DateTimeCalculation | undefined {
  if (query.length > 256 || /[\u0000-\u001f\u007f]/u.test(query)) return undefined;
  const text = query.trim().replace(/(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일/gu,
    (_, year: string, month: string, day: string) => `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`);
  let match = arithmeticPattern.exec(text);
  if (match) return addDays(match[1], match[3], match[2] === "+" ? 1 : -1);
  match = relativePattern.exec(text);
  if (match) return addDays(match[1], match[2], match[3] === "전" ? -1 : 1);
  match = differencePattern.exec(text);
  if (match) return difference(match[2], match[1]);
  match = intervalPattern.exec(text) ?? koreanDifferencePattern.exec(text);
  if (match) return difference(match[1], match[2]);
  // An explicit Korean source/destination pair: "서울에서 UTC로".
  match = timezonePattern.exec(text.replace(/에서\s+(\S+?)(?:으로|로)$/u, " to $1"));
  if (!match) return undefined;
  const [, date, hours, minutes, seconds, offset, source, target] = match;
  if (!source && !offset) return undefined;
  const midnight = dateTimestamp(date);
  if (Number(hours) > 23 || Number(minutes) > 59 || Number(seconds ?? 0) > 59) {
    fail("Invalid time. Use 00:00:00 through 23:59:59; leap seconds are not supported.");
  }
  const wall = midnight + Number(hours) * 3_600_000 + Number(minutes) * minuteMs + Number(seconds ?? 0) * 1000;
  const destination = resolveZone(target);
  const origin = source ? resolveZone(source) : undefined;
  const instant = origin ? localInstant(wall, origin, offset) : wall - offsetMinutes(offset!) * minuteMs;
  return {
    kind: "timezone", result: zoneResult(instant, destination),
    context: t("{0} → {1} · Device time-zone rules", { 0: origin ?? offset!, 1: destination }),
  };
}

export const dateTimeProvider: CommandProvider = {
  id: dateTimeProviderId,
  get label() { return t("Date and time"); },
  async search(query, signal) {
    if (signal.aborted) return [];
    const calculation = calculateDateTimeQuery(query);
    if (!calculation || signal.aborted) return [];
    const { result, context } = calculation;
    const item: CommandItem = {
      id: "datetime:result", providerId: dateTimeProviderId, title: result,
      subtitle: query.trim(), section: t("Date and time"), kind: "command",
      icon: "calculator", accent: "cyan", rankingBoost: 72, matchedQuery: query.trim(),
      answer: { kind: "calculation", input: query.trim(), value: result, context },
      data: { result },
      actions: [{ id: dateTimeActionIds.copyResult, title: t("Copy result"), shortcut: ["↵"], style: "accent" }],
    };
    return [item];
  },
};
