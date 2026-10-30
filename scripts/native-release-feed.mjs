// Signs a native release's updater archive and writes latest.json and SHA256SUMS.txt beside it.
//
//   TAURI_SIGNING_PRIVATE_KEY=… [TAURI_SIGNING_PRIVATE_KEY_PASSWORD=…] node scripts/native-release-feed.mjs <directory> <version>
//
// package-native-release.mjs calls this when the updater key is available locally; otherwise the
// "Sign native release" GitHub workflow runs it with the repository secret against a draft release's assets.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { signUpdaterFile } from "./sign-updater.mjs";
import { verifyUpdater } from "./verify-updater.mjs";

const minisignSource = new URL("../apps/mac/Sources/PrismUpdates/Signature/Minisign.swift", import.meta.url);

/// The updater public key the native app trusts.
export function nativePublicKey() {
  const key = /static let prismPublicKey = "([^"]+)"/.exec(readFileSync(minisignSource, "utf8"))?.[1];
  if (!key) throw new Error("Could not read the updater public key from the native app.");
  return key;
}

export const archiveName = (version) => `Prism_${version}_universal.app.tar.gz`;

export function writeChecksums(directory) {
  const sums = readdirSync(directory).filter(name => name !== "SHA256SUMS.txt" && !name.startsWith(".")).sort().map(name =>
    `${createHash("sha256").update(readFileSync(join(directory, name))).digest("hex")}  ${name}`);
  writeFileSync(join(directory, "SHA256SUMS.txt"), sums.join("\n") + "\n");
}

export function signRelease(directory, version, environment = process.env) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("The version must be a plain semantic version such as 0.2.0.");
  if (!environment.TAURI_SIGNING_PRIVATE_KEY) throw new Error("Set TAURI_SIGNING_PRIVATE_KEY to the existing updater key. Never create a new one.");
  const archive = archiveName(version);
  const signature = signUpdaterFile(join(directory, archive), environment.TAURI_SIGNING_PRIVATE_KEY,
    environment.TAURI_SIGNING_PRIVATE_KEY_PASSWORD ?? "");
  verifyUpdater(readFileSync(join(directory, archive)), signature, nativePublicKey());
  writeFileSync(join(directory, `${archive}.sig`), signature);

  const platform = { signature, url: `https://github.com/kmelon55/Prism/releases/download/v${version}/${archive}` };
  writeFileSync(join(directory, "latest.json"), JSON.stringify({
    version, notes: `Prism ${version}. See the GitHub release notes for changes.`, pub_date: new Date().toISOString(),
    platforms: { "darwin-aarch64": platform, "darwin-x86_64": platform },
  }, null, 2) + "\n");
  writeChecksums(directory);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [directory, version] = process.argv.slice(2);
  if (!directory || !version) throw new Error("Usage: node scripts/native-release-feed.mjs <directory> <version>");
  signRelease(directory, version);
  console.log(`Signed ${archiveName(version)} and wrote latest.json and SHA256SUMS.txt.`);
}
