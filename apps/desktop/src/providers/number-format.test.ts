import { describe, expect, it, vi } from "vitest";
import { groupDecimal, normalizeArithmeticExpression } from "./number-format";
import { calculatorProvider } from "./calculator";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));

describe("decimal grouping", () => {
  it.each([
    ["123456789012345678.123456789", "123,456,789,012,345,678.123456789"],
    ["-1234567.000100", "-1,234,567.000100"], ["0.000000000001", "0.000000000001"],
    ["1.25e+30", "1.25e+30"], ["1000", "1,000"], ["not a number", "not a number"],
  ])("preserves all digits in %s", (value, expected) => expect(groupDecimal(value)).toBe(expected));
  it("removes only well-formed grouping in arithmetic literals", () => {
    expect(normalizeArithmeticExpression("(1,000.25 + 20,000) / .5")).toBe("(1000.25 + 20000) / .5");
    for (const invalid of ["1,00+2", "12,34,567+1", "1.2,3+1", "1,,000+1", "1,000,+2"]) {
      expect(normalizeArithmeticExpression(invalid)).toBeUndefined();
    }
  });
  it("groups display values while sending canonical expressions and copying untouched native results", async () => {
    invoke.mockReset().mockResolvedValue("1234567.890123456789");
    const [item] = await calculatorProvider.search("1,000 + 2,000", new AbortController().signal);
    expect(invoke).toHaveBeenCalledWith("calculate_arithmetic", { expression: "1000 + 2000" });
    expect(item.answer?.value).toBe("1,234,567.890123456789");
    expect(item.answer?.input).toBe("1,000 + 2,000");
    expect(item.data?.result).toBe("1234567.890123456789");
    expect(item.matchedQuery).toBe("1,000 + 2,000");
    invoke.mockClear();
    expect(await calculatorProvider.search("1,00+2", new AbortController().signal)).toEqual([]);
    expect(invoke).not.toHaveBeenCalled();
  });
});
