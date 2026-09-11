import type { CSSProperties, InputHTMLAttributes } from "react";

type SettingsSliderProps = Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "value"> & {
  value: number;
};

export function SettingsSlider({ value, min = 0, max = 100, style, ...props }: SettingsSliderProps) {
  const lower = Number(min);
  const upper = Number(max);
  const progress = upper > lower ? Math.min(100, Math.max(0, (value - lower) / (upper - lower) * 100)) : 0;

  return <input {...props} type="range" min={min} max={max} value={value}
    style={{ ...style, "--range-progress": `${progress}%` } as CSSProperties} />;
}
