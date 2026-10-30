// Builds, signs and packages the Swift app (apps/mac) as a Prism release.
//
//   PRISM_INSTALLED_APP=/Applications/Prism.app [VERSION=0.2.0] node scripts/package-native-release.mjs
//
// The bundle keeps the identity installed copies update in place (Prism.app, dev.prism.desktop, executable
// prism-desktop) and is signed with the existing "Prism Local Signing" identity, never ad-hoc. The installed app is
// only inspected, never replaced.
//
// Output: dist/native-releases/v<version> with the DMG, ZIP, updater archive and checksums. With the updater key in
// TAURI_SIGNING_PRIVATE_KEY the archive is signed here and latest.json written too; without it, the "Sign native
// release" GitHub workflow signs the uploaded draft release with the repository secret.
//
// PRISM_APP_ONLY=1 stops after the signed and verified app, written to dist/native-app/Prism.app, for a local install
// with scripts/install-macos-app.mjs.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inspectSignature, resolveLocalSigningIdentity, verifyCompatibleSignatures } from "./macos-signing.mjs";
import { archiveName, signRelease, writeChecksums } from "./native-release-feed.mjs";

const environment = { ...process.env };
const version = environment.VERSION ?? JSON.parse(readFileSync("package.json", "utf8")).version;
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("VERSION must be a plain semantic version such as 0.2.0.");
if (!environment.PRISM_INSTALLED_APP) throw new Error("Set PRISM_INSTALLED_APP to the installed app whose signing identity must be preserved.");
const appOnly = environment.PRISM_APP_ONLY === "1";
const identity = resolveLocalSigningIdentity(environment);

const output = resolve(environment.PRISM_OUTPUT ?? (appOnly ? "dist/native-app" : `dist/native-releases/v${version}`));
const staging = mkdtempSync(join(tmpdir(), "prism-native-release-"));
try {
  execFileSync("/bin/zsh", ["scripts/build-app.sh"], {
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

  rmSync(output, { recursive: true, force: true });
  mkdirSync(output, { recursive: true });
  if (appOnly) {
    execFileSync("ditto", [app, join(output, "Prism.app")]);
    console.log(join(output, "Prism.app"));
  } else {
    packageRelease(app);
    console.log(output);
  }
} finally {
  rmSync(staging, { recursive: true, force: true });
}

// The updater archive, the DMG and ZIP installers and checksums, plus the signature and feed when the key is here.
function packageRelease(app) {
  const archive = archiveName(version);
  // COPYFILE_DISABLE keeps AppleDouble `._` files out of the archive.
  execFileSync("tar", ["-czf", join(output, archive), "-C", staging, "Prism.app"], { env: { ...environment, COPYFILE_DISABLE: "1" } });
  const listing = execFileSync("tar", ["-tzf", join(output, archive)], { encoding: "utf8" }).split("\n").filter(Boolean);
  if (listing.some(name => !name.startsWith("Prism.app/") || name.split("/").some(part => part.startsWith("._")))) {
    throw new Error("The updater archive has entries outside Prism.app or AppleDouble files.");
  }

  execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, join(output, `Prism_${version}_universal.zip`)]);
  const dmgFolder = join(staging, "dmg");
  mkdirSync(dmgFolder);
  execFileSync("ditto", [app, join(dmgFolder, "Prism.app")]);
  symlinkSync("/Applications", join(dmgFolder, "Applications"));
  // Create the drag-to-Applications image without mounting it or controlling Finder.
  execFileSync("hdiutil", ["create", "-volname", "Prism", "-srcfolder", dmgFolder, "-format", "UDZO", "-fs", "HFS+",
    "-ov", join(output, `Prism_${version}_universal.dmg`)], { stdio: "inherit" });

  if (environment.TAURI_SIGNING_PRIVATE_KEY) {
    signRelease(output, version, environment);
  } else {
    writeChecksums(output);
    console.log("No updater key here: upload these files to a draft release, then run the \"Sign native release\" workflow.");
  }
}
