/** Add grouping without converting a native decimal string to a lossy JS number. */
export function groupDecimal(value: string): string {
  const match = /^([+-]?)(\d+)(\.\d+)?([eE][+-]?\d+)?$/.exec(value);
  if (!match) return value;
  return `${match[1]}${match[2].replace(/\B(?=(\d{3})+(?!\d))/g, ",")}${match[3] ?? ""}${match[4] ?? ""}`;
}

/** Reject malformed grouping instead of silently changing the user's amount. */
export function ungroupDecimal(value: string): string | undefined {
  if (!/^[+-]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d*)?|\.\d+)$/.test(value)) return undefined;
  return value.replaceAll(",", "");
}

export function normalizeArithmeticExpression(value: string): string | undefined {
  let valid = true;
  const expression = value.replace(/[\d.,]+/g, (literal) => {
    const normalized = ungroupDecimal(literal);
    if (normalized === undefined) valid = false;
    return normalized ?? literal;
  });
  return valid ? expression : undefined;
}

export function groupExpression(value: string): string {
  return value.replace(/\d+(?:\.\d+)?/g, groupDecimal);
}
