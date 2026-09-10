import { t, useLocale } from "./i18n";
import { ArrowDown, Calculator, Coins, Ruler } from "lucide-react";
import type { CommandItem } from "@prism/command-core";

/** Lives inside the existing listbox option, preserving one selection and one copy action. */
export function InstantAnswer({ item }: { item: CommandItem }) {
  useLocale();
  const answer = item.answer!;
  const currency = answer.kind === "currency";
  const unit = answer.kind === "unit";
  return (
    <span className={`instant-answer-content${answer.stale ? " is-stale" : ""}`}>
      <span className="answer-heading">
        {currency ? <Coins size={15} aria-hidden="true" /> : unit ? <Ruler size={15} aria-hidden="true" /> : <Calculator size={15} aria-hidden="true" />}
        <span>{currency ? t("Currency conversion") : unit ? t("Unit conversion") : t("Calculator")}</span>
      </span>
      <span className="answer-input">
        <span>{answer.input}</span>
        {answer.inputUnit ? <span className="answer-unit">{answer.inputUnit}</span> : null}
      </span>
      <span className="answer-separator" aria-hidden="true">
        {currency || unit ? <ArrowDown size={19} /> : <span>=</span>}
      </span>
      <span className={`answer-value${answer.value.length > 16 ? " answer-value-long" : ""}`}>
        <strong>{answer.value}</strong>
        {answer.unit ? <span className="answer-unit">{answer.unit}</span> : null}
      </span>
      <span className="answer-context">{t(answer.context ?? "")}</span>
      {answer.note ? <span className="answer-note">{t(answer.note)}</span> : null}
    </span>
  );
}
