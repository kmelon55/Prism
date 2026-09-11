import { readFileSync, mkdirSync, copyFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { inspectSignature, verifyCompatibleSignatures } from "./macos-signing.mjs";
import { verifyUpdater } from "./verify-updater.mjs";

const version = JSON.parse(readFileSync("package.json", "utf8")).version;
const config = JSON.parse(readFileSync("apps/desktop/src-tauri/tauri.conf.json", "utf8"));
if (version !== config.version || (process.env.RELEASE_TAG && process.env.RELEASE_TAG !== `v${version}`)) throw new Error("Release tag and package versions must match.");
const bundle = "apps/desktop/src-tauri/target/universal-apple-darwin/release/bundle";
const output = `dist/releases/v${version}`;
const app = join(bundle, "macos/Prism.app");
const mode = process.env.PRISM_RELEASE_MODE;
if (mode !== "local-signed" && mode !== "notarized") {
  throw new Error("Set PRISM_RELEASE_MODE to local-signed or notarized explicitly.");
}
inspectSignature(app, { notarized: mode === "notarized", team: process.env.APPLE_TEAM_ID });
if (mode === "notarized") {
  execFileSync("xcrun", ["stapler", "validate", app], { stdio: "inherit" });
} else {
  if (!process.env.PRISM_INSTALLED_APP) throw new Error("Set PRISM_INSTALLED_APP to the installed app whose signing identity must be preserved.");
  verifyCompatibleSignatures(process.env.PRISM_INSTALLED_APP, app);
}
mkdirSync(output, { recursive: true });
const dmg = readdirSync(join(bundle, "dmg")).find(name => name.endsWith(".dmg"));
if (!dmg) throw new Error("DMG is missing.");
copyFileSync(join(bundle, "dmg", dmg), join(output, `Prism_${version}_universal.dmg`));
execFileSync("codesign", ["--verify", "--deep", "--strict", join(bundle, "macos/Prism.app")], { stdio: "inherit" });
execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", join(bundle, "macos/Prism.app"), join(output, `Prism_${version}_universal.zip`)]);
const archive = `Prism_${version}_universal.app.tar.gz`;
copyFileSync(join(bundle, "macos/Prism.app.tar.gz"), join(output, archive));
copyFileSync(join(bundle, "macos/Prism.app.tar.gz.sig"), join(output, `${archive}.sig`));
const platform = {
  signature: readFileSync(join(output, `${archive}.sig`), "utf8").trim(),
  url: `https://github.com/kmelon55/Prism/releases/download/v${version}/${archive}`,
};
verifyUpdater(readFileSync(join(output, archive)), platform.signature, config.plugins.updater.pubkey);
writeFileSync(join(output, "latest.json"), JSON.stringify({
  version, notes: `Prism ${version}. See the GitHub release notes for changes.`, pub_date: new Date().toISOString(),
  platforms: { "darwin-aarch64": platform, "darwin-x86_64": platform },
}, null, 2) + "\n");
const sums = readdirSync(output).filter(name => name !== "SHA256SUMS.txt").sort().map(name =>
  `${createHash("sha256").update(readFileSync(join(output, name))).digest("hex")}  ${name}`);
writeFileSync(join(output, "SHA256SUMS.txt"), sums.join("\n") + "\n");
console.log(output);
