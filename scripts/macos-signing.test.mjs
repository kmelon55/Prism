import test from "node:test";
import assert from "node:assert/strict";
import { requireSigningIdentity, requireReleaseCredentials, validateSignature } from "./macos-signing.mjs";

const details = 'Identifier=dev.prism.desktop\nAuthority=Developer ID Application: Prism (ABCDEFGHIJ)\nTeamIdentifier=ABCDEFGHIJ\n';
const requirement = 'designated => identifier "dev.prism.desktop" and anchor apple generic and certificate leaf[subject.OU] = ABCDEFGHIJ';

test("packaged builds cannot fall back to ad-hoc signing", () => {
  for (const identity of [undefined, "", " ", "-"]) {
    assert.throws(() => requireSigningIdentity({ APPLE_SIGNING_IDENTITY: identity }));
  }
  assert.equal(requireSigningIdentity({ APPLE_SIGNING_IDENTITY: "Prism Local Signing" }), "Prism Local Signing");
});

test("notarized releases require a complete Developer ID and notarization configuration", () => {
  const env = {
    APPLE_SIGNING_IDENTITY: "Developer ID Application: Prism (ABCDEFGHIJ)",
    APPLE_CERTIFICATE: "fixture", APPLE_CERTIFICATE_PASSWORD: "fixture",
    APPLE_ID: "fixture", APPLE_PASSWORD: "fixture", APPLE_TEAM_ID: "ABCDEFGHIJ",
    TAURI_SIGNING_PRIVATE_KEY: "fixture",
  };
  assert.doesNotThrow(() => requireReleaseCredentials(env));
  for (const name of Object.keys(env)) {
    assert.throws(() => requireReleaseCredentials({ ...env, [name]: "" }));
  }
  assert.throws(() => requireReleaseCredentials({ ...env, APPLE_TEAM_ID: "KLMNOPQRST" }));
  assert.throws(() => requireReleaseCredentials({ ...env, APPLE_SIGNING_IDENTITY: "Prism Local Signing" }));
});

test("reject ad-hoc, wrong application, wrong team and missing requirements", () => {
  assert.equal(validateSignature(details, requirement, { notarized: true, team: "ABCDEFGHIJ" }), requirement.slice(14));
  assert.throws(() => validateSignature(details + "Signature=adhoc\n", requirement));
  assert.throws(() => validateSignature(details, 'designated => cdhash H"012345"'));
  assert.throws(() => validateSignature(details.replace("dev.prism.desktop", "dev.prism.desktop.test"), requirement));
  assert.throws(() => validateSignature(details, ""));
  assert.throws(() => validateSignature(details, requirement, { team: "KLMNOPQRST" }));
  assert.throws(() => validateSignature(details.replace("Developer ID Application:", "Local:"), requirement, { notarized: true }));
});

test("non-notarized releases accept a persistent local certificate", () => {
  const localDetails = "Identifier=dev.prism.desktop\nAuthority=Prism Local Signing\n";
  const localRequirement = 'designated => identifier "dev.prism.desktop" and certificate leaf = H"012345"';
  assert.doesNotThrow(() => validateSignature(localDetails, localRequirement));
  assert.throws(() => validateSignature(localDetails, localRequirement, { notarized: true }));
});
