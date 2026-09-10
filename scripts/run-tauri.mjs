import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { delimiter } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const desktopDirectory = join(scriptDirectory, "..", "apps", "desktop");
const cliPackage = require.resolve("@tauri-apps/cli/package.json", {
  paths: [desktopDirectory],
});
const cliManifest = require(cliPackage);
const cliEntry = join(dirname(cliPackage), cliManifest.bin.tauri);

const environment = { ...process.env };
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
