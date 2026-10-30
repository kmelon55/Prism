import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const applicationIdentifier = "dev.prism.desktop";

export function requireSigningIdentity(environment) {
  const identity = environment.APPLE_SIGNING_IDENTITY?.trim();
  if (!identity || identity === "-") {
    throw new Error("A persistent APPLE_SIGNING_IDENTITY is required for a macOS app build. Ad-hoc updates invalidate macOS permissions. See docs/releases.md.");
  }
  return identity;
}

/**
 * Selects the existing "Prism Local Signing" identity from its dedicated keychain, as configured by
 * setup-local-macos-signing.mjs, unless APPLE_SIGNING_IDENTITY already names one. Never creates certificates.
 */
export function resolveLocalSigningIdentity(environment) {
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
  return requireSigningIdentity(environment);
}

export function requireReleaseCredentials(environment) {
  const identity = requireSigningIdentity(environment);
  if (!identity.startsWith("Developer ID Application:")) {
    throw new Error("Notarized macOS releases require a Developer ID Application signing identity.");
  }
  for (const name of ["APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_ID", "APPLE_PASSWORD", "APPLE_TEAM_ID", "TAURI_SIGNING_PRIVATE_KEY"]) {
    if (!environment[name]?.trim()) throw new Error(`Missing release secret: ${name}`);
  }
  const team = identity.match(/\(([A-Z0-9]{10})\)$/)?.[1];
  if (team !== environment.APPLE_TEAM_ID) throw new Error("The signing identity and notarization team must match.");
}

export function validateSignature(details, requirement, { notarized = false, team } = {}) {
  const field = (name) => details.split("\n").find((line) => line.startsWith(`${name}=`))?.slice(name.length + 1);
  if (field("Identifier") !== applicationIdentifier) throw new Error("The signed application must keep the Prism bundle identifier.");
  if (field("Signature") === "adhoc" || !field("Authority") || /\bcdhash\b/.test(requirement)) {
    throw new Error("The app has an unstable ad-hoc identity; it must not replace an installed Prism app.");
  }
  if (!requirement.startsWith("designated => ") || !requirement.includes(`identifier \"${applicationIdentifier}\"`)) {
    throw new Error("The app is missing a persistent designated requirement for Prism.");
  }
  if (notarized && !field("Authority")?.startsWith("Developer ID Application:")) {
    throw new Error("Notarized releases must use Developer ID Application signing.");
  }
  if (team && field("TeamIdentifier") !== team) throw new Error("The built app has the wrong signing team.");
  return requirement.slice("designated => ".length);
}

function codesign(args) {
  // codesign writes signature information to stderr, including on success.
  const result = execFileSync("/usr/bin/codesign", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  return result;
}

export function inspectSignature(bundle, options) {
  codesign(["--verify", "--deep", "--strict", "--all-architectures", bundle]);
  // spawnSync keeps the diagnostic stderr available without printing certificate data.
  const detail = readCodesign(["-dv", "--verbose=4", bundle]);
  const requirement = readCodesign(["-dr", "-", bundle]).split("\n")
    .find((line) => line.startsWith("designated => ") || line.startsWith("# designated => "))?.replace(/^# /, "") ?? "";
  return validateSignature(detail, requirement, options);
}

function readCodesign(args) {
  const result = spawnSync("/usr/bin/codesign", args, { encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error("Could not inspect the application code signature.");
  return result.stdout + result.stderr;
}

export function verifyCompatibleSignatures(installed, candidate) {
  const previousRequirement = inspectSignature(installed);
  const nextRequirement = inspectSignature(candidate);
  // Check both directions: neither a new signer nor a broadened requirement may slip in.
  codesign(["--verify", "--strict", "--all-architectures", "-R", `=${previousRequirement}`, candidate]);
  codesign(["--verify", "--strict", "--all-architectures", "-R", `=${nextRequirement}`, installed]);
}
