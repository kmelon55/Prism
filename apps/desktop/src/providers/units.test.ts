import { describe, expect, it } from "vitest";
import { convertUnitQuery, unitProvider } from "./units";

describe("local unit conversion", () => {
  it.each([
    ["10 cm to inch", "3.93700787402", "in"], ["1 inch to cm", "2.54", "cm"],
    ["1마일 킬로미터", "1.609344", "km"], ["1,000 m to km", "1", "km"],
    ["1000미터 킬로미터로", "1", "km"], ["2.5 kg to g", "2500", "g"],
    ["1 lb to kg", "0.45359237", "kg"], ["1 oz to g", "28.349523125", "g"],
    ["32 F to C", "0", "°C"], ["100 섭씨 화씨", "212", "°F"],
    ["-40 °C to °F", "-40", "°F"], ["-273.15 C to K", "0", "K"],
    ["0 K to C", "-273.15", "°C"], ["-459.67 F to K", "0", "K"],
    ["2 L to ml", "2000", "mL"], ["1 m3 to L", "1000", "L"],
    ["2시간 분", "120", "min"], ["1 d to h", "24", "h"], [".5 h to min", "30", "min"],
    ["1 m2 to cm2", "10000", "cm²"], ["1 ft2 to m2", "0.09290304", "m²"],
    ["1 GB to MB", "1000", "MB"], ["1 GiB to MiB", "1024", "MiB"],
    ["1 GB to MiB", "953.674316406", "MiB"], ["8 Mb to MB", "1", "MB"],
    ["1 B to b", "8", "b"], ["1,234.56789 m to m", "1234.56789", "m"],
  ])("converts %s", (query, expected, label) => {
    const conversion = convertUnitQuery(query)!;
    expect(conversion.result).toBe(expected);
    expect(conversion.to.label).toBe(label);
  });
  it.each(["paper", "100", "100달러", "100 USD to KRW", "1,00 m to km", "1e3 m to km", "1 mb to MB", "1 m/s to km/h", "1 gallon to L", "10 m to cm\n"])("does not guess unsupported syntax: %s", (query) => {
    expect(convertUnitQuery(query)).toBeUndefined();
  });
  it("reports incompatible dimensions and impossible temperatures", () => {
    expect(() => convertUnitQuery("1 kg to cm")).toThrow("same kind");
    expect(() => convertUnitQuery("-1 K to C")).toThrow("absolute zero");
    expect(() => convertUnitQuery("-274 C to F")).toThrow("absolute zero");
    expect(() => convertUnitQuery("-0.000000000001 K to C")).toThrow("absolute zero");
    expect(() => convertUnitQuery("1000000000001 m to cm")).toThrow("no larger");
  });
  it("returns a query-correlated large answer with a plain copy value", async () => {
    const [item] = await unitProvider.search("1 GB to B", new AbortController().signal);
    expect(item.answer).toMatchObject({ kind: "unit", input: "1", inputUnit: "GB", value: "1,000,000,000", unit: "B" });
    expect(item.data?.result).toBe("1000000000");
    expect(item.matchedQuery).toBe("1 GB to B");
    const controller = new AbortController();
    controller.abort();
    expect(await unitProvider.search("1 GB to B", controller.signal)).toEqual([]);
  });
});
