import { ChevronDown } from "lucide-react";
import { t, useLocale } from "../i18n";
import type { ClipboardTypeFilterValue } from "../providers/clipboard";

export interface ClipboardTypeFilterProps {
  value: ClipboardTypeFilterValue;
  onChange: (value: ClipboardTypeFilterValue) => void;
  disabled?: boolean;
}
export function ClipboardTypeFilter({ value, onChange, disabled }: ClipboardTypeFilterProps) {
  useLocale();
  return <label className="clipboard-type-filter">
    <span>{t("Clipboard type")}</span>
    <span className="clipboard-type-control"><select aria-label={t("Clipboard type")} value={value} disabled={disabled} onChange={(event) => onChange(event.target.value as ClipboardTypeFilterValue)}>
      <option value="all">{t("All types")}</option>
      <option value="text">{t("Text")}</option>
      <option value="image">{t("Images")}</option>
      <option value="files">{t("Files")}</option>
    </select><ChevronDown size={12} aria-hidden="true" /></span>
  </label>;
}
