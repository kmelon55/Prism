import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { delimiter } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { requireSigningIdentity } from "./macos-signing.mjs";
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const require = createRequire(import.meta.url);
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const desktopDirectory = join(scriptDirectory, "..", "apps", "desktop");
const cliPackage = require.resolve("@tauri-apps/cli/package.json", {
  paths: [desktopDirectory],
});
const cliManifest = require(cliPackage);
const cliEntry = join(dirname(cliPackage), cliManifest.bin.tauri);

const environment = { ...process.env };
const args = process.argv.slice(2);
if (process.platform === "darwin" && ["build", "bundle"].includes(args[0]) && !args.includes("--help")) {
  const localIdentity = join(homedir(), "Library/Application Support/Prism Signing/identity.json");
  if (!environment.CI && !environment.APPLE_SIGNING_IDENTITY && existsSync(localIdentity)) {
    const identity = JSON.parse(readFileSync(localIdentity, "utf8"));
    const password = readFileSync(identity.passwordFile, "utf8").trim();
    const unlocked = spawnSync("/usr/bin/security", ["unlock-keychain", "-p", password, identity.keychain], { stdio: "ignore" });
    if (unlocked.status !== 0) throw new Error("Could not unlock Prism's signing keychain. The app was not built.");
    const available = spawnSync("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", identity.keychain], { encoding: "utf8" });
    if (!available.stdout?.includes(identity.identity)) throw new Error("The configured Prism signing identity is unavailable in its keychain.");
    environment.APPLE_SIGNING_IDENTITY = identity.identity;
  }
  environment.APPLE_SIGNING_IDENTITY = requireSigningIdentity(environment);
}
// Keep local Rust builds compact while retaining file/line information in backtraces.
// Explicit environment overrides still allow full native debugging when needed.
environment.CARGO_PROFILE_DEV_DEBUG ??= "line-tables-only";
environment.CARGO_PROFILE_DEV_INCREMENTAL ??= "false";
const pathKey = Object.keys(environment).find((key) => key.toLowerCase() === "path") ?? "PATH";
const cargoHome = environment.CARGO_HOME || join(homedir(), ".cargo");
environment[pathKey] = [join(cargoHome, "bin"), environment[pathKey]]
  .filter(Boolean)
  .join(delimiter);

const child = spawn(process.execPath, [cliEntry, ...process.argv.slice(2)], {
  cwd: process.cwd(),
  env: environment,
  stdio: "inherit",
});

child.on("error", (error) => {
  console.error(`Failed to start the Tauri CLI: ${error.message}`);
  process.exitCode = 1;
});

child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exitCode = code ?? 1;
});
