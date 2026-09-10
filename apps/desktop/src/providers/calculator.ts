import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import type { CommandItem, CommandProvider } from "@prism/command-core";
import { groupDecimal, groupExpression, normalizeArithmeticExpression } from "./number-format";

export const calculatorProviderId = "calculator";

export const calculatorActionIds = {
  copyResult: "copy-calculator-result",
} as const;

const maximumExpressionLength = 256;
const arithmeticCandidate = /^[\d\s()+\-*/.,]+$/u;

function canBeArithmetic(query: string): boolean {
  if (query.length === 0 || query.length > maximumExpressionLength) return false;
  const expression = query.trim();
  return (
    expression.length > 0 &&
    arithmeticCandidate.test(expression) &&
    /[+\-*/]/u.test(expression)
  );
}

export const calculatorProvider: CommandProvider = {
  id: calculatorProviderId,
  get label() { return t("Calculator"); },
  async search(query, signal) {
    if (signal.aborted || !canBeArithmetic(query)) return [];

    const expression = normalizeArithmeticExpression(query.trim());
    if (expression === undefined) return [];
    const result = await invoke<string | null>("calculate_arithmetic", { expression });
    if (signal.aborted || result === null) return [];

    const item: CommandItem = {
      id: "calculator:result",
      providerId: calculatorProviderId,
      title: groupDecimal(result),
      subtitle: groupExpression(expression),
      section: t("Calculator"),
      kind: "command",
      keywords: ["arithmetic", "calculate"],
      icon: "calculator",
      accent: "cyan",
      rankingBoost: 72,
      matchedQuery: query.trim(),
      answer: { kind: "calculation", input: groupExpression(expression), value: groupDecimal(result), context: t("Calculated on this device") },
      detail: {
        eyebrow: "Instant calculation",
        title: groupDecimal(result),
        description: groupExpression(expression),
        metadata: [
          { label: t("Expression"), value: expression },
          { label: t("Result"), value: result },
          { label: t("Runtime"), value: "Local device" },
        ],
      },
      data: { expression, result },
      actions: [
        {
          id: calculatorActionIds.copyResult,
          title: t("Copy result"),
          shortcut: ["↵"],
          style: "accent",
        },
      ],
    };

    return [item];
  },
};
