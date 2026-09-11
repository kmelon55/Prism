import { inspectSignature, verifyCompatibleSignatures } from "./macos-signing.mjs";

const [bundle, installed] = process.argv.slice(2);
if (!bundle) throw new Error("Usage: node scripts/verify-macos-signing.mjs candidate.app [installed.app]");
inspectSignature(bundle, { notarized: process.env.PRISM_RELEASE_MODE === "notarized", team: process.env.APPLE_TEAM_ID });
if (installed) verifyCompatibleSignatures(installed, bundle);
console.log(installed ? "Prism update preserves the installed signing identity." : "Prism has a persistent signing identity.");
