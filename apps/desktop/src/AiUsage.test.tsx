import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { AiUsage } from "./AiUsage";
import { rowCost, usageCost, type UsageSummary } from "./providers/aiUsage";
const { invoke, listen } = vi.hoisted(() => ({ invoke: vi.fn(), listen: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen }));
let root: Root; let host: HTMLDivElement;
const totals = { requests: 2, inputTokens: 300, outputTokens: 40, knownCostUsd: 0.0012, unknownCostRequests: 1, unknownTokenRequests: 1, estimatedRequests: 1 };
const fixture: UsageSummary = { month: totals, allTime: totals, features: [{ ...totals, feature: "cleanup" }], breakdown: [{...totals,feature:"cleanup",provider:"vercel",model:"fixture/model"}], daily: [], recent: [{ id: 1, startedAt: Date.now(), feature: "prompt", provider: "vercel", model: "fixture/model", status: "completed", inputTokens: 300, outputTokens: 40, costUsd: 0.0012, costKind: "estimated" }] };
beforeEach(() => {
  localStorage.clear(); Object.defineProperty(navigator, "language", { configurable: true, value: "en-US" });
  invoke.mockReset().mockResolvedValue(fixture); listen.mockReset().mockResolvedValue(() => {});
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
});
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });
it("shows unknown costs as incomplete, never as free", () => {
  expect(usageCost(totals)).toBe("≈ $0.0012 + ?");
  expect(usageCost({ ...totals, unknownCostRequests: 2 })).toBe("Cost unavailable");
  expect(rowCost({ ...fixture.recent[0], costUsd: null })).toBe("Cost unavailable");
  expect(rowCost({ ...fixture.recent[0], costUsd: 0, costKind: "reported" })).toBe("$0");
});
it("refreshes the receipt and totals on a native usage event", async () => {
  await act(async () => root.render(<AiUsage nativeRuntime />));
  expect(host.textContent).toContain("300 in / 40 out");
  expect(host.textContent).toContain("≈ $0.0012 + ?");
  const update = listen.mock.calls.find(([name]) => name === "prism:ai-usage-changed")![1];
  invoke.mockResolvedValue({ ...fixture, month: { ...totals, requests: 3 } });
  await act(async () => update({}));
  expect(host.querySelector(".usage-totals")?.textContent).toContain("Requests3");
  const since = invoke.mock.calls[0][1].since;
  expect(new Date(since).getDate()).toBe(1); expect(new Date(since).getHours()).toBe(0);
});
it("shows a retryable error instead of zero totals on read failure", async () => {
  invoke.mockRejectedValue("disk error");
  await act(async () => root.render(<AiUsage nativeRuntime />));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Could not read AI usage.");
  expect(host.textContent).not.toContain("$0");
  invoke.mockResolvedValue(fixture);
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="Refresh AI usage"]')!.click());
  expect(host.querySelector('[role="alert"]')).toBeNull();
});
it("does not call native APIs in browser preview", async () => {
  await act(async () => root.render(<AiUsage nativeRuntime={false} />));
  expect(invoke).not.toHaveBeenCalled(); expect(listen).not.toHaveBeenCalled();
  expect(host.textContent).toContain("Usage appears after using AI in the desktop app.");
});
it("distinguishes zero-cost local usage from unavailable provider costs in the graph", async () => {
  const free = {...totals,knownCostUsd:0,unknownCostRequests:0,estimatedRequests:0};
  invoke.mockResolvedValue({...fixture,month:free});
  await act(async()=>root.render(<AiUsage nativeRuntime/>));
  expect(host.querySelector('.usage-timeline path')).not.toBeNull();
  expect(host.querySelector('.usage-chart-empty')).toBeNull();
  invoke.mockResolvedValue({...fixture,month:{...free,unknownCostRequests:free.requests}});
  await act(async()=>host.querySelector<HTMLButtonElement>('[aria-label="Refresh AI usage"]')!.click());
  expect(host.querySelector('.usage-chart-empty')?.textContent).toBe("Cost unavailable");
  expect(host.querySelector('.usage-timeline path')).toBeNull();
});
