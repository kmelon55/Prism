import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Check, ChevronDown } from "lucide-react";
import "./settingsSelect.css";
export interface SelectOption { value: string; label: string; disabled?: boolean }
export function SettingsSelect({ value, options, onChange, disabled = false, label, className = "" }: {
  value: string; options: SelectOption[]; onChange(value: string): void; disabled?: boolean; label: string; className?: string;
}) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const [position, setPosition] = useState({ left: 0, top: 0, width: 180, maxHeight: 300 });
  const chosen = options.findIndex(option => option.value === value);
  const close = (focus = false) => { setOpen(false); if (focus) trigger.current?.focus(); };
  function show() {
    if (disabled || trigger.current?.matches(":disabled")) return;
    setActive(chosen < 0 ? 0 : chosen); setOpen(true);
  }
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const box = trigger.current?.getBoundingClientRect(); if (!box) return;
      const height = Math.min(320, options.length * 36 + 12);
      const below = innerHeight - box.bottom - 12;
      const above = box.top - 12;
      const maxHeight = Math.max(60, Math.min(height, below >= Math.min(height, 160) ? below : above));
      const width = Math.min(innerWidth - 24, Math.max(box.width, 200));
      setPosition({ left: Math.max(12, Math.min(box.right - width, innerWidth - width - 12)), top: below >= Math.min(height, 160) ? box.bottom + 6 : Math.max(12, box.top - maxHeight - 6), width, maxHeight });
    };
    place(); menu.current?.focus();
    window.addEventListener("resize", place); window.addEventListener("scroll", place, true);
    return () => { window.removeEventListener("resize", place); window.removeEventListener("scroll", place, true); };
  }, [open, options.length]);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!menu.current?.contains(event.target as Node) && !trigger.current?.contains(event.target as Node)) setOpen(false); };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", outside); window.addEventListener("blur", blur);
    return () => { document.removeEventListener("pointerdown", outside); window.removeEventListener("blur", blur); };
  }, [open]);
  useEffect(() => { if (open) (menu.current?.children[active] as HTMLElement | undefined)?.scrollIntoView?.({ block: "nearest" }); }, [active, open, id]);
  const move = (direction: number) => {
    for (let n = 1; n <= options.length; n++) { const next = (active + direction * n + options.length) % options.length; if (!options[next].disabled) { setActive(next); break; } }
  };
  return <>
    <button ref={trigger} type="button" className={`settings-select ${className}`} role="combobox" aria-label={label} aria-expanded={open} aria-controls={open ? id : undefined} aria-haspopup="listbox" disabled={disabled} onClick={() => open ? close() : show()} onKeyDown={event => {
      if (["ArrowDown", "ArrowUp", "Enter", " "].includes(event.key)) { event.preventDefault(); show(); }
    }}><span>{options[chosen]?.label ?? value}</span><ChevronDown size={13} /></button>
    {open && createPortal(<div ref={menu} id={id} role="listbox" aria-label={label} aria-activedescendant={`${id}-${active}`} tabIndex={-1} className="settings-select-menu" style={position} onKeyDown={event => {
      if (event.nativeEvent.isComposing) return;
      if (event.key === "Tab") { close(true); return; }
      event.stopPropagation();
      if (["ArrowDown", "ArrowUp", "Home", "End", "Enter", " ", "Escape"].includes(event.key)) event.preventDefault();
      if (event.key === "Escape") close(true);
      else if (event.key === "ArrowDown" || event.key === "ArrowUp") move(event.key === "ArrowDown" ? 1 : -1);
      else if (event.key === "Home") setActive(options.findIndex(option => !option.disabled));
      else if (event.key === "End") setActive(options.length - 1 - [...options].reverse().findIndex(option => !option.disabled));
      else if (["Enter", " "].includes(event.key) && options[active] && !options[active].disabled) { onChange(options[active].value); close(true); }
      else if (event.key.length === 1) { const next = options.findIndex(option => !option.disabled && option.label.toLocaleLowerCase().startsWith(event.key.toLocaleLowerCase())); if (next >= 0) setActive(next); }
    }}>
      {options.map((option, index) => <button type="button" tabIndex={-1} role="option" id={`${id}-${index}`} key={option.value} aria-selected={option.value === value} disabled={option.disabled} data-active={index === active} onPointerMove={() => setActive(index)} onClick={() => { onChange(option.value); close(true); }}><span>{option.label}</span>{option.value === value && <Check size={14} />}</button>)}
    </div>, document.body)}
  </>;
}
