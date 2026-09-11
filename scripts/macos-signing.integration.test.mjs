import test from "node:test";
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { inspectSignature, verifyCompatibleSignatures } from "./macos-signing.mjs";

function localIdentity() {
  const config = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Prism Signing/identity.json"), "utf8"));
  const password = readFileSync(config.passwordFile, "utf8").trim();
  const unlocked = spawnSync("/usr/bin/security", ["unlock-keychain", "-p", password, config.keychain], { stdio: "ignore" });
  assert.equal(unlocked.status, 0, "unlock the existing dedicated signing keychain");
  return config;
}

test("two different native builds retain the same local identity; ad-hoc replacements fail", { skip: process.platform !== "darwin" }, () => {
  const config = localIdentity();
  const root = mkdtempSync(join(tmpdir(), "prism-signing-test-"));
  const run = (command, args) => execFileSync(command, args, { stdio: "pipe", timeout: 15000 });
  try {
    for (const [name, code] of [["previous", 0], ["next", 1], ["adhoc", 2]]) {
      writeFileSync(join(root, `${name}.c`), `int main(void) { return ${code}; }\n`);
      run("cc", [join(root, `${name}.c`), "-o", join(root, name)]);
      run("/usr/bin/codesign", ["--force", "--sign", name === "adhoc" ? "-" : config.identity, "--keychain", config.keychain, "--identifier", "dev.prism.desktop", join(root, name)]);
    }
    assert.notDeepEqual(readFileSync(join(root, "previous")), readFileSync(join(root, "next")));
    assert.equal(inspectSignature(join(root, "previous")), inspectSignature(join(root, "next")));
    assert.doesNotThrow(() => verifyCompatibleSignatures(join(root, "previous"), join(root, "next")));
    assert.throws(() => verifyCompatibleSignatures(join(root, "previous"), join(root, "adhoc")));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("local signing preserves restart access but a changed build requires Keychain approval", { skip: process.platform !== "darwin" }, () => {
  const config = localIdentity();
  const root = mkdtempSync(join(tmpdir(), "prism-keychain-test-"));
  const service = `dev.prism.signing-fixture.${process.pid}.${Date.now()}`;
  const run = (command, args) => execFileSync(command, args, { stdio: "pipe", timeout: 15000 });
  const previous = join(root, "previous");
  const next = join(root, "next");
  const untrusted = join(root, "untrusted");
  const installed = join(root, "installed");
  let created = false;
  try {
    writeFileSync(join(root, "fixture.c"), `
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  CFStringRef service = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query, kSecAttrService, service);
  CFDictionarySetValue(query, kSecAttrAccount, CFSTR("fixture"));
  CFDictionarySetValue(query, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
  const UInt8 fixture[] = "prism-synthetic-test-key";
  CFDataRef expected = CFDataCreate(NULL, fixture, sizeof(fixture) - 1);
  // The file-based login keychain needs a scoped legacy UI policy too.
  Boolean previous = true;
  if (SecKeychainGetUserInteractionAllowed(&previous) || SecKeychainSetUserInteractionAllowed(false)) return 3;
  OSStatus status;
  if (!strcmp(argv[1], "write")) {
    CFDictionarySetValue(query, kSecValueData, expected);
    status = SecItemAdd(query, NULL);
  } else if ((!strcmp(argv[1], "read") || !strcmp(argv[1], "denied"))) {
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFTypeRef result = NULL;
    status = SecItemCopyMatching(query, &result);
    if (!status && (!result || !CFEqual(expected, result))) status = -1;
    if (result) CFRelease(result);
  } else { status = SecItemDelete(query); }
  SecKeychainSetUserInteractionAllowed(previous);
  CFRelease(query); CFRelease(service); CFRelease(expected);
  if (!strcmp(argv[1], "denied")) return (status == errSecInteractionNotAllowed || status == errSecAuthFailed) ? 0 : 4;
  if (status) fprintf(stderr, "Fixture version %d failed: %d\\n", VERSION, (int)status);
  return status ? 1 : 0;
}
`);
    for (const [path, version] of [[previous, 1], [next, 2], [untrusted, 3]]) {
      run("cc", [`-DVERSION=${version}`, "-Wno-deprecated-declarations", join(root, "fixture.c"), "-framework", "Security", "-framework", "CoreFoundation", "-o", path]);
      run("/usr/bin/codesign", ["--force", "--sign", config.identity, "--keychain", config.keychain, "--identifier", version === 3 ? "dev.prism.signing.untrusted-fixture" : "dev.prism.signing.keychain-fixture", path]);
    }
    copyFileSync(previous, installed);
    run(installed, ["write", service]); created = true;
    assert.doesNotThrow(() => run(installed, ["read", service]), "the same signed build can read after restart");
    rmSync(installed); copyFileSync(next, installed);
    // Self-signed clients are partitioned by CDHash, not the stable certificate
    // requirement. Changing a build therefore needs a new user approval.
    assert.doesNotThrow(() => run(installed, ["denied", service]));
    assert.doesNotThrow(() => run(untrusted, ["denied", service]));
    // The original authorized build still works after other identities are denied.
    rmSync(installed); copyFileSync(previous, installed);
    assert.doesNotThrow(() => run(installed, ["read", service]));
  } finally {
    try { if (created) { rmSync(installed); copyFileSync(previous, installed); run(installed, ["delete", service]); } }
    finally { rmSync(root, { recursive: true, force: true }); }
  }
});
