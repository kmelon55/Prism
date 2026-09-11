import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { inspectSignature, verifyCompatibleSignatures } from "./macos-signing.mjs";

test("two different native builds retain the same local identity; ad-hoc replacements fail", { skip: process.platform !== "darwin" }, () => {
  const config = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Prism Signing/identity.json"), "utf8"));
  const root = mkdtempSync(join(tmpdir(), "prism-signing-test-"));
  const run = (command, args) => execFileSync(command, args, { stdio: "pipe" });
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

test("a second signed build reads the first build's fixture key without authentication UI", { skip: process.platform !== "darwin" }, () => {
  const config = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Prism Signing/identity.json"), "utf8"));
  const root = mkdtempSync(join(tmpdir(), "prism-keychain-test-"));
  const service = `dev.prism.signing-fixture.${process.pid}.${Date.now()}`;
  const run = (command, args) => execFileSync(command, args, { stdio: "pipe" });
  const previous = join(root, "previous");
  const next = join(root, "next");
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
  OSStatus status;
  if (!strcmp(argv[1], "write")) {
    CFDictionarySetValue(query, kSecValueData, expected);
    status = SecItemAdd(query, NULL);
  } else if (!strcmp(argv[1], "read")) {
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFTypeRef result = NULL;
    status = SecItemCopyMatching(query, &result);
    if (!status && (!result || !CFEqual(expected, result))) status = -1;
    if (result) CFRelease(result);
  } else { status = SecItemDelete(query); }
  CFRelease(query); CFRelease(service); CFRelease(expected);
  if (status) fprintf(stderr, "Fixture version %d failed: %d\\n", VERSION, (int)status);
  return status ? 1 : 0;
}
`);
    for (const [path, version] of [[previous, 1], [next, 2]]) {
      run("cc", [`-DVERSION=${version}`, "-Wno-deprecated-declarations", join(root, "fixture.c"), "-framework", "Security", "-framework", "CoreFoundation", "-o", path]);
      run("/usr/bin/codesign", ["--force", "--sign", config.identity, "--keychain", config.keychain, "--identifier", "dev.prism.signing.keychain-fixture", path]);
    }
    run(previous, ["write", service]); created = true;
    assert.doesNotThrow(() => run(next, ["read", service]));
  } finally {
    try { if (created) run(previous, ["delete", service]); }
    finally { rmSync(root, { recursive: true, force: true }); }
  }
});
