import { t } from "../i18n";
import type { CommandItem, CommandProvider } from "@prism/command-core";
import { groupDecimal, ungroupDecimal } from "./number-format";

export const unitActionIds = { copyResult: "copy-unit-result" } as const;
type Family = "Length" | "Mass" | "Temperature" | "Volume" | "Duration" | "Area" | "Data size";
interface Unit { family: Family; label: string; scale: number; offset: number }
const units = new Map<string, Unit>();
function define(family: Family, label: string, scale: number, aliases: string[], offset = 0) {
  const unit = { family, label, scale, offset };
  for (const alias of [label, ...aliases]) units.set(alias, unit);
}

define("Length", "mm", 0.001, ["millimeter", "millimeters", "밀리미터"]);
define("Length", "cm", 0.01, ["centimeter", "centimeters", "센티미터"]);
define("Length", "m", 1, ["meter", "meters", "미터"]);
define("Length", "km", 1000, ["kilometer", "kilometers", "킬로미터"]);
define("Length", "in", 0.0254, ["inch", "inches", "인치"]);
define("Length", "ft", 0.3048, ["foot", "feet", "피트"]);
define("Length", "yd", 0.9144, ["yard", "yards", "야드"]);
define("Length", "mi", 1609.344, ["mile", "miles", "마일"]);
define("Mass", "mg", 0.000001, ["milligram", "milligrams", "밀리그램"]);
define("Mass", "g", 0.001, ["gram", "grams", "그램"]);
define("Mass", "kg", 1, ["kilogram", "kilograms", "킬로그램"]);
define("Mass", "t", 1000, ["tonne", "tonnes", "metric ton", "톤"]);
define("Mass", "oz", 0.028349523125, ["ounce", "ounces", "온스"]);
define("Mass", "lb", 0.45359237, ["lbs", "pound", "pounds", "파운드"]);
define("Temperature", "°C", 1, ["C", "celsius", "섭씨"], 273.15);
define("Temperature", "°F", 5 / 9, ["F", "fahrenheit", "화씨"], 273.15 - 32 * 5 / 9);
define("Temperature", "K", 1, ["kelvin", "켈빈"]);
define("Volume", "mL", 0.001, ["ml", "milliliter", "milliliters", "밀리리터"]);
define("Volume", "L", 1, ["l", "liter", "liters", "litre", "litres", "리터"]);
define("Volume", "m³", 1000, ["m3", "cubic meter", "cubic meters", "세제곱미터"]);
define("Duration", "ms", 0.001, ["millisecond", "milliseconds", "밀리초"]);
define("Duration", "s", 1, ["sec", "second", "seconds", "초"]);
define("Duration", "min", 60, ["minute", "minutes", "분"]);
define("Duration", "h", 3600, ["hr", "hour", "hours", "시간"]);
define("Duration", "d", 86400, ["day", "days", "일"]);
define("Duration", "wk", 604800, ["week", "weeks", "주"]);
define("Area", "cm²", 0.0001, ["cm2", "제곱센티미터"]);
define("Area", "m²", 1, ["m2", "sqm", "제곱미터"]);
define("Area", "km²", 1000000, ["km2", "제곱킬로미터"]);
define("Area", "ft²", 0.09290304, ["ft2", "sqft", "제곱피트"]);
define("Area", "ha", 10000, ["hectare", "hectares", "헥타르"]);
define("Data size", "B", 1, ["byte", "bytes", "바이트"]);
define("Data size", "b", 1 / 8, ["bit", "bits", "비트"]);
for (const [prefix, power] of [["k", 1], ["M", 2], ["G", 3], ["T", 4]] as const) {
  define("Data size", `${prefix}B`, 1000 ** power, prefix === "k" ? ["KB"] : []);
  define("Data size", `${prefix}b`, 1000 ** power / 8, prefix === "k" ? ["Kb"] : []);
}
for (const [prefix, power] of [["Ki", 1], ["Mi", 2], ["Gi", 3], ["Ti", 4]] as const) {
  define("Data size", `${prefix}B`, 1024 ** power, []);
  define("Data size", `${prefix}b`, 1024 ** power / 8, []);
}
// Full English names may ignore case; symbols deliberately preserve it (MB != Mb).
function resolveUnit(text: string): Unit | undefined {
  return units.get(text) ?? (text.length > 3 ? units.get(text.toLowerCase()) : undefined);
}
const amountPattern = "[+-]?(?:(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d{1,12})?|\\.\\d{1,12})";
const queryPattern = new RegExp(`^(${amountPattern})\\s*(.+?)\\s+(?:to|in|->|→|=)\\s*(.+)$`, "i");
const koreanPattern = new RegExp(`^(${amountPattern})\\s*(.+?)\\s+(.+?)(?:으로|로)?$`);
export interface UnitConversion { amount: string; from: Unit; to: Unit; result: string }

export function convertUnitQuery(query: string): UnitConversion | undefined {
  if (query.length > 160 || /[\u0000-\u001f\u007f]/u.test(query)) return undefined;
  const match = queryPattern.exec(query.trim()) ?? koreanPattern.exec(query.trim());
  if (!match) return undefined;
  const amount = ungroupDecimal(match[1]);
  const from = resolveUnit(match[2].trim());
  const to = resolveUnit(match[3].trim());
  if (amount === undefined || !from || !to) return undefined;
  if (from.family !== to.family) throw new Error(`Cannot convert ${from.label} to ${to.label}: choose units of the same kind.`);
  const numeric = Number(amount);
  if (!Number.isFinite(numeric) || Math.abs(numeric) > 1e12) throw new Error("Use an amount no larger than 1,000,000,000,000.");
  let base = numeric * from.scale + from.offset;
  if (from.family === "Temperature") {
    const minimum = from.label === "°C" ? -273.15 : from.label === "°F" ? -459.67 : 0;
    if (numeric < minimum) throw new Error("Temperature cannot be below absolute zero.");
    base = Math.max(0, base);
  }
  const converted = from === to ? numeric : (base - to.offset) / to.scale;
  // Bound display noise from floating-point conversion; the copy value is the same displayed number.
  const result = from === to ? numeric.toString() : Number(converted.toPrecision(12)).toString();
  return { amount, from, to, result: result === "-0" ? "0" : result };
}

export const unitProvider: CommandProvider = {
  id: "units", label: "Unit conversion",
  async search(query, signal) {
    if (signal.aborted) return [];
    const conversion = convertUnitQuery(query);
    if (!conversion) return [];
    const { amount, from, to, result } = conversion;
    const value = groupDecimal(result);
    const input = groupDecimal(amount);
    const item: CommandItem = {
      id: "units:result", providerId: "units", title: `${input} ${from.label} = ${value} ${to.label}`,
      section: "Unit conversion", kind: "command", matchedQuery: query.trim(), icon: "ruler",
      answer: { kind: "unit", input, inputUnit: from.label, value, unit: to.label, context: t("{0} · Converted on this device",{0:t(from.family)}),
        note: from.family === "Data size" ? "B = bytes · b = bits · kB/MB/GB use 1,000 · KiB/MiB/GiB use 1,024" : undefined },
      data: { result },
      actions: [{ id: unitActionIds.copyResult, title: "Copy result", shortcut: ["↵"], style: "accent" }],
    };
    return [item];
  },
};
