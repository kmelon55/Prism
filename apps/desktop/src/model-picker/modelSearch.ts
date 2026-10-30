type SearchableModel = { name: string; id: string; ownedBy?: string };

const normalize = (value: string) => value.normalize("NFKC").toLowerCase();
const separators = /[\s\p{Pd}_/:]+/u;
const compact = (value: string) => value.split(separators).join("");

// Model names and IDs use different word separators. Keep version dots
// meaningful, but allow spacing differences and words in any order.
export function createModelSearch(query: string): (model: SearchableModel) => boolean {
  const normalized = normalize(query);
  const joined = compact(normalized);
  const terms = normalized.split(separators).filter(Boolean);
  if (!terms.length) return () => true;

  return model => {
    const fields = [model.name, model.id, model.ownedBy ?? ""].map(value => compact(normalize(value)));
    return fields.some(field => field.includes(joined))
      || terms.every(term => fields.some(field => field.includes(term)));
  };
}
