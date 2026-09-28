import { createHash, randomBytes, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const android = join(root, 'apps/android');
const signingHome = join(homedir(), '.local/share/prism-android-signing');
const configPath = join(signingHome, 'signing.json');
const identityPath = join(android, 'release-signing.json');
const signingNames = ['ANDROID_KEYSTORE_PATH', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD'];
const repo = 'kmelon55/Prism';

function run(command, args, options = {}) {
  return execFileSync(command, args, { cwd: root, encoding: 'utf8', stdio: ['pipe', 'pipe', 'inherit'], ...options });
}

export function readVersion(text) {
  const values = Object.fromEntries(text.split(/\r?\n/).filter(line => line.trim() && !line.startsWith('#')).map(line => line.trim().split('=')));
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(values.versionName ?? '') || !/^[1-9]\d*$/.test(values.versionCode ?? '')) {
    throw new Error('Use a stable three-part versionName and a positive integer versionCode.');
  }
  const code = Number(values.versionCode);
  if (!Number.isSafeInteger(code) || code > 2100000000) throw new Error('versionCode exceeds the Android limit.');
  return { name: values.versionName, code, tag: `android-v${values.versionName}` };
}

function version() { return readVersion(readFileSync(join(android, 'version.properties'), 'utf8')); }

function validatePublication() {
  const v = version();
  if (process.env.RELEASE_TAG !== v.tag) throw new Error('Release tag must match the Android version.properties file.');
  const releases = JSON.parse(run('gh', ['api', `repos/${repo}/releases`, '--paginate', '--slurp'])).flat();
  const current = releases.find(item => item.tag_name === v.tag);
  if (current && !current.draft) throw new Error('Published Android releases are immutable. Bump both version fields.');
  for (const release of releases.filter(item => !item.draft && /^android-v/.test(item.tag_name))) {
    const previous = JSON.parse(run('gh', ['release', 'download', release.tag_name, '--repo', repo, '--pattern', 'release.json', '--output', '-']));
    if (!Number.isInteger(previous.code) || v.code <= previous.code) throw new Error('versionCode must exceed every published Android version.');
  }
  console.log(`Validated ${v.tag} (versionCode ${v.code})`);
}
function keytool() { return process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin/keytool') : 'keytool'; }
function sdkTool(name) {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
  if (!sdk) throw new Error('Set ANDROID_HOME to an Android SDK with build-tools 35.0.0.');
  return join(sdk, 'build-tools/35.0.0', name);
}

function signingEnvironment() {
  const supplied = signingNames.filter(name => process.env[name]);
  if (supplied.length && supplied.length !== signingNames.length) throw new Error('Incomplete Android signing environment.');
  const values = supplied.length ? Object.fromEntries(signingNames.map(name => [name, process.env[name]])) : JSON.parse(readFileSync(configPath, 'utf8'));
  if (!signingNames.every(name => typeof values[name] === 'string' && values[name])) throw new Error('Invalid signing configuration.');
  if (!isAbsolute(values.ANDROID_KEYSTORE_PATH) || !existsSync(values.ANDROID_KEYSTORE_PATH)) throw new Error('Signing keystore must exist at an absolute path.');
  return { ...process.env, ...values };
}

function certificate(env) {
  const bytes = run(keytool(), ['-exportcert', '-keystore', env.ANDROID_KEYSTORE_PATH, '-alias', env.ANDROID_KEY_ALIAS,
    '-storepass:env', 'ANDROID_KEYSTORE_PASSWORD'], { env, encoding: 'buffer' });
  const cert = new X509Certificate(bytes);
  if (/Android Debug/i.test(cert.subject)) throw new Error('A debug certificate cannot be used for distribution.');
  return { sha256: cert.fingerprint256.replaceAll(':', '').toLowerCase(), subject: cert.subject };
}

function verifyIdentity(env) {
  const actual = certificate(env);
  const expected = JSON.parse(readFileSync(identityPath, 'utf8'));
  if (actual.sha256 !== expected.sha256) throw new Error('Release signing certificate differs from the pinned identity.');
  return actual;
}

function setupSigning() {
  if (existsSync(configPath)) {
    const identity = verifyIdentity(signingEnvironment());
    console.log(`Reusing Android signing identity ${identity.sha256}`);
    return;
  }
  if (existsSync(identityPath) || existsSync(signingHome)) {
    throw new Error('Signing state already exists. Restore the original keystore; never replace it automatically.');
  }
  mkdirSync(signingHome, { recursive: true, mode: 0o700 });
  chmodSync(signingHome, 0o700);
  const password = randomBytes(36).toString('base64url');
  const values = {
    ANDROID_KEYSTORE_PATH: join(signingHome, 'prism-release.jks'),
    ANDROID_KEYSTORE_PASSWORD: password,
    ANDROID_KEY_ALIAS: 'prism-release',
    ANDROID_KEY_PASSWORD: password,
  };
  const env = { ...process.env, ...values };
  run(keytool(), ['-genkeypair', '-keystore', values.ANDROID_KEYSTORE_PATH, '-storetype', 'JKS', '-alias', values.ANDROID_KEY_ALIAS,
    '-keyalg', 'RSA', '-keysize', '4096', '-validity', '10000', '-dname', 'CN=Prism Android, O=Prism',
    '-storepass:env', 'ANDROID_KEYSTORE_PASSWORD', '-keypass:env', 'ANDROID_KEY_PASSWORD'], { env });
  chmodSync(values.ANDROID_KEYSTORE_PATH, 0o600);
  writeFileSync(configPath, `${JSON.stringify(values, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  writeFileSync(identityPath, `${JSON.stringify(certificate(env), null, 2)}\n`, { flag: 'wx' });
  console.log(`Created persistent signing material in ${signingHome}. Keep an encrypted offline backup of this directory.`);
}

function configureGithub() {
  const env = signingEnvironment();
  verifyIdentity(env);
  const secrets = {
    ANDROID_KEYSTORE_BASE64: readFileSync(env.ANDROID_KEYSTORE_PATH).toString('base64'),
    ANDROID_KEYSTORE_PASSWORD: env.ANDROID_KEYSTORE_PASSWORD,
    ANDROID_KEY_ALIAS: env.ANDROID_KEY_ALIAS,
    ANDROID_KEY_PASSWORD: env.ANDROID_KEY_PASSWORD,
  };
  for (const [name, value] of Object.entries(secrets)) {
    run('gh', ['secret', 'set', name, '--repo', repo], { input: value });
    console.log(`Configured ${name}`);
  }
}

export function obtainiumLink(config) {
  return `https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/${encodeURIComponent(JSON.stringify(config))}`;
}

export function verifyApkMetadata(badging, v) {
  const line = badging.split('\n').find(item => item.startsWith('package:')) || '';
  if (!line.includes("name='app.prism.launcher'") || !line.includes(`versionCode='${v.code}'`) || !line.includes(`versionName='${v.name}'`)) {
    throw new Error('APK application ID or version does not match version.properties.');
  }
  if (/^application-debuggable/m.test(badging)) throw new Error('Debuggable APKs cannot be distributed.');
}

function packageRelease() {
  const v = version();
  if (process.env.RELEASE_TAG && process.env.RELEASE_TAG !== v.tag) throw new Error('Release tag and version.properties disagree.');
  const identity = verifyIdentity(signingEnvironment());
  const apk = join(android, 'app/build/outputs/apk/release/app-release.apk');
  const signatures = run(sdkTool('apksigner'), ['verify', '--verbose', '--print-certs', apk]);
  const hashes = [...signatures.matchAll(/^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)$/gm)].map(match => match[1]);
  if (hashes.length !== 1 || hashes[0] !== identity.sha256) throw new Error('APK signer does not match the pinned release certificate.');
  verifyApkMetadata(run(sdkTool('aapt'), ['dump', 'badging', apk]), v);
  const output = join(root, 'dist/android', v.tag);
  mkdirSync(output, { recursive: true });
  const apkName = `Prism-Android-${v.name}.apk`;
  copyFileSync(apk, join(output, apkName));
  const config = JSON.parse(readFileSync(join(android, 'obtainium.json'), 'utf8'));
  // File imports accept an app array; the deep link accepts one app object.
  writeFileSync(join(output, 'obtainium.json'), `${JSON.stringify([config], null, 2)}\n`);
  const commit = run('git', ['rev-parse', 'HEAD']).trim();
  const checksum = createHash('sha256').update(readFileSync(apk)).digest('hex');
  writeFileSync(join(output, 'release.json'), `${JSON.stringify({ ...v, applicationId: 'app.prism.launcher', commit, apk: apkName, sha256: checksum, certificateSha256: identity.sha256 }, null, 2)}\n`);
  const assets = [apkName, 'obtainium.json', 'release.json'];
  writeFileSync(join(output, 'SHA256SUMS.txt'), assets.map(name => `${createHash('sha256').update(readFileSync(join(output, name))).digest('hex')}  ${name}\n`).join(''));
  const notes = readFileSync(join(android, 'release-notes.md'), 'utf8');
  writeFileSync(join(output, 'release-notes.md'), `${notes}\n\n[Add Prism Android to Obtainium](${obtainiumLink(config)})\n\nSigning certificate SHA-256: \`${identity.sha256}\`\n`);
  console.log(`Verified release assets: ${output}`);
}

async function main() {
  switch (process.argv[2]) {
    case 'setup-signing': setupSigning(); break;
    case 'configure-github': configureGithub(); break;
    case 'build': {
      const env = signingEnvironment();
      verifyIdentity(env);
      run(join(android, 'gradlew'), ['--no-daemon', ':app:testDebugUnitTest', ':app:lintRelease', ':app:assembleRelease'], { cwd: android, env, stdio: 'inherit' });
      packageRelease();
      break;
    }
    case 'package': packageRelease(); break;
    case 'version': console.log(JSON.stringify(version())); break;
    case 'validate-publication': validatePublication(); break;
    case 'obtainium-link': console.log(obtainiumLink(JSON.parse(readFileSync(join(android, 'obtainium.json'), 'utf8')))); break;
    default: throw new Error('Usage: node scripts/android-release.mjs setup-signing|configure-github|build|package|version|validate-publication|obtainium-link');
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
