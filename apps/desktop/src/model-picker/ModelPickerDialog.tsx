import { useLayoutEffect, useRef, type HTMLAttributes, type RefObject } from "react";
import "./model-picker.css";

type Props = HTMLAttributes<HTMLDivElement> & { onDismiss(): void; returnFocusRef?: RefObject<HTMLElement | null> };

// A native modal escapes transformed/scrolling settings ancestors without
// moving the React subtree. WebKit also makes the underlying window inert.
export function ModelPickerDialog({ onDismiss, returnFocusRef, children, className = "", onKeyDown, "aria-label": label, ...props }: Props) {
  const dialog = useRef<HTMLDialogElement>(null);
  const restoreTarget = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    const element = dialog.current!;
    restoreTarget.current ??= returnFocusRef?.current ?? document.activeElement as HTMLElement | null;
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    if (element.showModal && !element.open) element.showModal();
    else element.setAttribute("open", ""); // DOM-only test environments.
    (element.querySelector<HTMLElement>('input[type="search"]') ?? element.querySelector<HTMLElement>('button:not(:disabled)'))?.focus({ preventScroll: true });

    // Stop wheel momentum at list boundaries, including older WKWebViews.
    const containWheel = (event: WheelEvent) => {
      if (event.ctrlKey) return;
      let node = event.target instanceof Element ? event.target : null;
      while (node && node !== element) {
        if (node instanceof HTMLElement && /(auto|scroll)/.test(getComputedStyle(node).overflowY)) {
          const remaining = node.scrollHeight - node.clientHeight - node.scrollTop;
          if ((event.deltaY > 0 && remaining > 1) || (event.deltaY < 0 && node.scrollTop > 1)) return;
        }
        node = node.parentElement;
      }
      event.preventDefault();
    };
    element.addEventListener("wheel", containWheel, { passive: false });
    return () => {
      element.removeEventListener("wheel", containWheel);
      document.body.style.overflow = overflow;
      // StrictMode replays effects while the modal is still mounted. Restoring
      // focus then would dismiss it through the owner's outside-blur handler.
      queueMicrotask(() => {
        if (!element.isConnected && restoreTarget.current?.isConnected) restoreTarget.current.focus({ preventScroll: true });
      });
    };
  }, [returnFocusRef]);

  return <dialog ref={dialog} className="model-picker-dialog" role="dialog" aria-label={label} aria-modal="true"
    onCancel={event => { event.preventDefault(); event.stopPropagation(); onDismiss(); }}
    onClick={event => { if (event.target === event.currentTarget) onDismiss(); }}
    onKeyDown={event => {
      if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return;
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onDismiss(); }
      if (event.key === "Tab") {
        event.preventDefault(); event.stopPropagation();
        const controls = [...event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled), select:not(:disabled), summary, a[href]')]
          .filter(control => !control.closest("[hidden], [inert]") && (!control.closest("details:not([open])") || control.tagName === "SUMMARY"));
        const index = controls.indexOf(document.activeElement as HTMLElement);
        controls[(index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length]?.focus();
      }
    }}>
    <div {...props} className={`model-picker-surface ${className}`} onKeyDown={onKeyDown}>{children}</div>
  </dialog>;
}
