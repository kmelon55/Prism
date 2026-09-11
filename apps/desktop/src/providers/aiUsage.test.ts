import { expect, it } from "vitest";
import { emptyUsageTotals, groupUsage, monthDays } from "./aiUsage";
it("groups every feature/provider/model tuple while retaining unknown counts",()=>{
  const rows=[{...emptyUsageTotals,feature:"cleanup",provider:"openai",model:"same",requests:20,knownCostUsd:2},{...emptyUsageTotals,feature:"prompt",provider:"openai",model:"same",requests:8,knownCostUsd:1},{...emptyUsageTotals,feature:"prompt",provider:"vercel",model:"same",requests:2,unknownCostRequests:2}];
  expect(groupUsage(rows,"model","cost")).toMatchObject([{name:"openai / same",requests:28,knownCostUsd:3},{name:"vercel / same",requests:2,unknownCostRequests:2}]);
  expect(groupUsage(rows,"feature","requests")).toMatchObject([{name:"cleanup",requests:20},{name:"prompt",requests:10,unknownCostRequests:2}]);
});
it("fills the local calendar without making future usage or treating missing data as requests",()=>{
  const days=monthDays([{...emptyUsageTotals,day:"2026-02-02",requests:5}],new Date(2026,1,3));
  expect(days).toHaveLength(28);expect(days[1].requests).toBe(5);expect(days[2].future).toBe(false);expect(days[3].future).toBe(true);expect(days[0].requests).toBe(0);
});
