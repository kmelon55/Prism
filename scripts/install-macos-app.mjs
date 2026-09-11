import { existsSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { inspectSignature, verifyCompatibleSignatures } from "./macos-signing.mjs";

if (process.platform !== "darwin") throw new Error("This installer requires macOS.");
const args = process.argv.slice(2);
const flags = args.filter((arg) => arg.startsWith("--"));
if (flags.some((flag) => flag !== "--migrate-from-adhoc")) throw new Error("Unknown installer option.");
const source = resolve(args.find((arg) => !arg.startsWith("--")) ?? "apps/desktop/src-tauri/target/universal-apple-darwin/release/bundle/macos/Prism.app");
const installed = "/Applications/Prism.app";
const executable = join(installed, "Contents/MacOS/prism-desktop");
if (source === installed) throw new Error("Choose a newly built app as the installation source.");
inspectSignature(source);
const running = execFileSync("/bin/ps", ["-axo", "comm="], { encoding: "utf8" }).split("\n").some((line) => line.trim() === executable);
if (running) throw new Error("Quit the installed Prism app before updating. No app or development server was stopped.");
if (existsSync(installed)) {
  const details = spawnSync("/usr/bin/codesign", ["-dv", installed], { encoding: "utf8" });
  const migrating = details.status === 0 && details.stderr.includes("Signature=adhoc") && flags.includes("--migrate-from-adhoc");
  if (!migrating) verifyCompatibleSignatures(installed, source);
}

const staging = mkdtempSync(join(dirname(installed), ".prism-install-"));
const candidate = join(staging, "Prism.app");
const previous = join(staging, "previous");
let movedPrevious = false;
let placedCandidate = false;
let committed = false;
try {
  execFileSync("/usr/bin/ditto", [source, candidate]);
  inspectSignature(candidate);
  if (existsSync(installed)) {
    const backup = join(mkdtempSync(join(tmpdir(), "prism-app-backup-")), "Prism.zip");
    execFileSync("/usr/bin/ditto", ["-c", "-k", "--keepParent", installed, backup]);
    console.log(`Previous app backup: ${backup}`);
    renameSync(installed, previous); movedPrevious = true;
  }
  renameSync(candidate, installed); placedCandidate = true;
  inspectSignature(installed);
  committed = true;
} catch (error) {
  if (placedCandidate) rmSync(installed, { recursive: true, force: true });
  if (movedPrevious) { renameSync(previous, installed); movedPrevious = false; }
  throw error;
} finally {
  // If restoring the previous app failed, preserve staging for recovery.
  if (!movedPrevious || committed) rmSync(staging, { recursive: true, force: true });
}
console.log("Installed Prism with its persistent signing identity. Application data and Keychain items were preserved.");
