// Builds, signs and packages the Swift app (apps/mac) as a Prism release that the installed Tauri app can update to.
//
//   TAURI_SIGNING_PRIVATE_KEY=… TAURI_SIGNING_PRIVATE_KEY_PASSWORD=… \
//   PRISM_INSTALLED_APP=/Applications/Prism.app [VERSION=0.2.0] node scripts/package-native-release.mjs
//
// The bundle keeps the Tauri identity (Prism.app, dev.prism.desktop, executable prism-desktop) and is signed with the
// existing "Prism Local Signing" identity, never ad-hoc. The installed app is only inspected, never replaced.
// Output: dist/native-releases/v<version> with the DMG, ZIP, updater archive and signature, latest.json and checksums.
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inspectSignature, resolveLocalSigningIdentity, verifyCompatibleSignatures } from "./macos-signing.mjs";
import { signUpdaterFile } from "./sign-updater.mjs";
import { verifyUpdater } from "./verify-updater.mjs";

const environment = { ...process.env };
const version = environment.VERSION ?? JSON.parse(readFileSync("package.json", "utf8")).version;
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("VERSION must be a plain semantic version such as 0.2.0.");
if (!environment.PRISM_INSTALLED_APP) throw new Error("Set PRISM_INSTALLED_APP to the installed app whose signing identity must be preserved.");
if (!environment.TAURI_SIGNING_PRIVATE_KEY) throw new Error("Set TAURI_SIGNING_PRIVATE_KEY to the existing updater key. Never create a new one.");
// The key the native app trusts for later updates, and, while it exists, the key the installed Tauri app trusts.
const publicKeys = [/static let prismPublicKey = "([^"]+)"/.exec(readFileSync("apps/mac/Sources/PrismUpdates/Signature/Minisign.swift", "utf8"))?.[1]];
if (!publicKeys[0]) throw new Error("Could not read the updater public key from the native app.");
if (existsSync("apps/desktop/src-tauri/tauri.conf.json")) {
  publicKeys.push(JSON.parse(readFileSync("apps/desktop/src-tauri/tauri.conf.json", "utf8")).plugins.updater.pubkey);
}
const identity = resolveLocalSigningIdentity(environment);

const output = resolve(environment.PRISM_OUTPUT ?? `dist/native-releases/v${version}`);
const staging = mkdtempSync(join(tmpdir(), "prism-native-release-"));
try {
  execFileSync("/bin/zsh", ["apps/mac/scripts/build-app.sh"], {
    stdio: "inherit",
    env: { ...environment, CONFIG: "release", BUNDLE_ID: "dev.prism.desktop", APP_NAME: "Prism", EXECUTABLE: "prism-desktop",
           VERSION: version, SCRATCH: ".build-release", OUTPUT: staging },
    cwd: "apps/mac",
  });
  const app = join(staging, "Prism.app");

  // The updater archive must hold only regular files and directories.
  const links = execFileSync("find", [app, "-type", "l"], { encoding: "utf8" }).trim();
  if (links) throw new Error(`The app bundle contains symbolic links:\n${links}`);

  execFileSync("/usr/bin/codesign", ["--force", "--options", "runtime", "--timestamp=none",
    "--entitlements", "apps/mac/Resources/Prism.entitlements", "--sign", identity, app], { stdio: "inherit" });
  inspectSignature(app);
  verifyCompatibleSignatures(environment.PRISM_INSTALLED_APP, app);
  const entitlements = spawnSync("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app], { encoding: "utf8" }).stdout;
  for (const key of ["com.apple.security.device.audio-input", "com.apple.security.automation.apple-events"]) {
    if (!entitlements.includes(key)) throw new Error(`The signed app is missing the ${key} entitlement.`);
  }

  mkdirSync(output, { recursive: true });
  const archive = `Prism_${version}_universal.app.tar.gz`;
  // COPYFILE_DISABLE keeps AppleDouble `._` files out of the archive.
  execFileSync("tar", ["-czf", join(output, archive), "-C", staging, "Prism.app"], { env: { ...environment, COPYFILE_DISABLE: "1" } });
  const listing = execFileSync("tar", ["-tzf", join(output, archive)], { encoding: "utf8" }).split("\n").filter(Boolean);
  if (listing.some(name => !name.startsWith("Prism.app/") || name.split("/").some(part => part.startsWith("._")))) {
    throw new Error("The updater archive has entries outside Prism.app or AppleDouble files.");
  }
  // The existing updater key signs the archive, so the installed Tauri app accepts it.
  const signature = signUpdaterFile(join(output, archive), environment.TAURI_SIGNING_PRIVATE_KEY,
    environment.TAURI_SIGNING_PRIVATE_KEY_PASSWORD ?? "");
  writeFileSync(join(output, `${archive}.sig`), signature);
  for (const key of publicKeys) verifyUpdater(readFileSync(join(output, archive)), signature, key);

  execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, join(output, `Prism_${version}_universal.zip`)]);
  const dmgFolder = join(staging, "dmg");
  mkdirSync(dmgFolder);
  execFileSync("ditto", [app, join(dmgFolder, "Prism.app")]);
  symlinkSync("/Applications", join(dmgFolder, "Applications"));
  // Create the drag-to-Applications image without mounting it or controlling Finder.
  execFileSync("hdiutil", ["create", "-volname", "Prism", "-srcfolder", dmgFolder, "-format", "UDZO", "-fs", "HFS+",
    "-ov", join(output, `Prism_${version}_universal.dmg`)], { stdio: "inherit" });

  const platform = { signature, url: `https://github.com/kmelon55/Prism/releases/download/v${version}/${archive}` };
  writeFileSync(join(output, "latest.json"), JSON.stringify({
    version, notes: `Prism ${version}. See the GitHub release notes for changes.`, pub_date: new Date().toISOString(),
    platforms: { "darwin-aarch64": platform, "darwin-x86_64": platform },
  }, null, 2) + "\n");
  const sums = readdirSync(output).filter(name => name !== "SHA256SUMS.txt").sort().map(name =>
    `${createHash("sha256").update(readFileSync(join(output, name))).digest("hex")}  ${name}`);
  writeFileSync(join(output, "SHA256SUMS.txt"), sums.join("\n") + "\n");
  console.log(output);
} finally {
  rmSync(staging, { recursive: true, force: true });
}
