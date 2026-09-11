// One persistent local identity. Never regenerate it during a build or app update.
import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";

if (process.platform !== "darwin") throw new Error("Local macOS signing setup requires macOS.");
const root = join(homedir(), "Library/Application Support/Prism Signing");
mkdirSync(root, { recursive: true, mode: 0o700 });
chmodSync(root, 0o700);
const manifest = join(root, "identity.json");
const passwordFile = join(root, "keychain-password");
const certificate = join(root, "certificate.pem");
const archive = join(root, "identity.p12");
const keychain = join(root, "signing.keychain-db");
const openssl = existsSync("/opt/homebrew/opt/openssl@3/bin/openssl") ? "/opt/homebrew/opt/openssl@3/bin/openssl" : "/usr/bin/openssl";
const password = existsSync(passwordFile) ? readFileSync(passwordFile, "utf8").trim() : randomBytes(32).toString("hex");
writeFileSync(passwordFile, password, { mode: 0o600 });

function run(command, args, input) {
  const result = spawnSync(command, args, { input, encoding: "utf8" });
  if (result.error || result.status !== 0) {
    const detail = (result.stderr || result.error?.message || "Command failed").replaceAll(password, "[redacted]");
    throw new Error(`${command} failed: ${detail}`);
  }
  return result.stdout;
}

if (!existsSync(manifest)) {
  if (existsSync(certificate) || existsSync(archive)) throw new Error(`An incomplete identity exists in ${root}. Recover it instead of generating a different identity.`);
  const privateKey = join(root, "private-key.pem");
  try {
    run(openssl, ["req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-days", "3650", "-subj", "/CN=Prism Local Signing/",
      "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "keyUsage=critical,digitalSignature",
      "-addext", "extendedKeyUsage=critical,codeSigning", "-keyout", privateKey, "-out", certificate]);
    chmodSync(privateKey, 0o600);
    const args = ["pkcs12", "-export", "-name", "Prism Local Signing", "-inkey", privateKey, "-in", certificate, "-out", archive, "-passout", "stdin"];
    if (openssl.includes("openssl@3")) args.push("-legacy");
    run(openssl, args, `${password}\n`);
    chmodSync(archive, 0o600);
    const identity = run(openssl, ["x509", "-in", certificate, "-noout", "-fingerprint", "-sha1"]).split("=")[1].trim().replaceAll(":", "");
    writeFileSync(manifest, JSON.stringify({ identity, keychain, passwordFile, certificate }, null, 2) + "\n", { mode: 0o600 });
  } finally {
    if (existsSync(privateKey)) unlinkSync(privateKey);
  }
}
const config = JSON.parse(readFileSync(manifest, "utf8"));
if (!existsSync(keychain)) run("/usr/bin/security", ["create-keychain", "-p", password, keychain]);
run("/usr/bin/security", ["unlock-keychain", "-p", password, keychain]);
const identities = run("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain]);
if (!identities.includes(config.identity)) {
  run("/usr/bin/security", ["import", archive, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"]);
  run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain]);
}
if (!run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", keychain]).includes(config.identity)) {
  console.log("macOS may ask you to approve this certificate once. Trust is limited to code signing in your user account.");
  run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain, certificate]);
}
if (!run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", keychain]).includes(config.identity)) {
  throw new Error("macOS has not approved the local signing certificate. The installed Prism app was not changed.");
}
const searchList = run("/usr/bin/security", ["list-keychains", "-d", "user"])
  .split("\n").map((line) => line.trim().replace(/^"|"$/g, "")).filter(Boolean);
if (!searchList.includes(keychain)) run("/usr/bin/security", ["list-keychains", "-d", "user", "-s", ...searchList, keychain]);
console.log(`Local signing identity is ready. Keep a secure backup of ${root}. Public releases still require Developer ID signing.`);
