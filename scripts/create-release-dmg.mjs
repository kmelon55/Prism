import { mkdtempSync, mkdirSync, rmSync, symlinkSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { inspectSignature } from "./macos-signing.mjs";

const version = JSON.parse(readFileSync("package.json", "utf8")).version;
const bundle = resolve("apps/desktop/src-tauri/target/universal-apple-darwin/release/bundle");
const app = join(bundle, "macos/Prism.app");
inspectSignature(app);
const staging = mkdtempSync(join(tmpdir(), "prism-dmg-"));
try {
  execFileSync("ditto", [app, join(staging, "Prism.app")]);
  symlinkSync("/Applications", join(staging, "Applications"));
  mkdirSync(join(bundle, "dmg"), { recursive: true });
  // Create the drag-to-Applications image without mounting it or controlling Finder.
  execFileSync("hdiutil", ["create", "-volname", "Prism", "-srcfolder", staging,
    "-format", "UDZO", "-fs", "HFS+", join(bundle, "dmg", `Prism_${version}_universal.dmg`)], { stdio: "inherit" });
} finally {
  rmSync(staging, { recursive: true, force: true });
}
