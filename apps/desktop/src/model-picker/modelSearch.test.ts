import { expect, it } from "vitest";
import { createModelSearch } from "./modelSearch";

const models = [
  { id: "openai/gpt-4o-mini", name: "GPT-4o Mini" },
  { id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5" },
  { id: "whisper-large-v3", name: "Whisper Large v3", ownedBy: "OpenAI" },
];

it.each(["gpt 4o", "  GPT   4o  mini  ", "gpt4omini", "g p t 4o", "GPT_4o/Mini", "ＧＰＴ　４ｏ", "gpt–4o", "mini openai", "4o\tmini"])(
  "finds the same model for %j", query => {
    expect(models.filter(createModelSearch(query))).toEqual([models[0]]);
  },
);

it("matches reordered words across names, IDs, and owners", () => {
  expect(models.filter(createModelSearch("4.5 anthropic sonnet"))).toEqual([models[1]]);
  expect(models.filter(createModelSearch("openai large whisper"))).toEqual([models[2]]);
});

it.each(["", "   ", "\t\n\u00a0\u3000"])("shows all models for blank query %j", query => {
  expect(models.filter(createModelSearch(query))).toEqual(models);
});

it("requires every term and preserves version distinctions", () => {
  expect(models.filter(createModelSearch("gpt unknown"))).toEqual([]);
  expect(models.filter(createModelSearch("sonnet 45"))).toEqual([]);
  expect(models.filter(createModelSearch("sonnet 4.6"))).toEqual([]);
});
