import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readVersion, obtainiumLink, verifyApkMetadata } from './android-release.mjs';

test('Android versions have a separate tag namespace and bounded integer code', () => {
  assert.deepEqual(readVersion('versionName=0.1.0\nversionCode=2\n'), { name: '0.1.0', code: 2, tag: 'android-v0.1.0' });
  for (const value of ['0', '-1', '2.5', '2100000001', 'NaN']) {
    assert.throws(() => readVersion(`versionName=0.1.0\nversionCode=${value}`));
  }
  assert.throws(() => readVersion('versionName=0.1.0-beta\nversionCode=2'));
});

test('Obtainium import carries Android-only release and APK filters', () => {
  const config = JSON.parse(readFileSync(new URL('../apps/android/obtainium.json', import.meta.url), 'utf8'));
  const settings = JSON.parse(config.additionalSettings);
  const title = new RegExp(settings.filterReleaseTitlesByRegEx);
  const apk = new RegExp(settings.apkFilterRegEx);
  assert.equal(title.test('Prism Android 0.1.0'), true);
  assert.equal(title.test('Prism v0.1.13'), false);
  assert.equal(apk.test('Prism-Android-0.1.0.apk'), true);
  assert.equal(apk.test('Prism-Android-0.1.0Xapk'), false);
  assert.equal(apk.test('Prism_0.1.13_universal.dmg'), false);
  assert.equal(settings.verifyLatestTag, false);
  assert.equal(settings.versionDetection, true);
  assert.equal('android-v0.1.0'.match(new RegExp(settings.versionExtractionRegEx))[0], '0.1.0');
  const encoded = obtainiumLink(config).split('obtainium://app/')[1];
  assert.deepEqual(JSON.parse(decodeURIComponent(encoded)), config);
});

test('Release verification rejects mismatched versions, IDs, and debuggable APKs', () => {
  const v = readVersion('versionName=0.1.0\nversionCode=2');
  const good = "package: name='app.prism.launcher' versionCode='2' versionName='0.1.0'\n";
  assert.doesNotThrow(() => verifyApkMetadata(good, v));
  assert.throws(() => verifyApkMetadata(good.replace("versionCode='2'", "versionCode='1'"), v));
  assert.throws(() => verifyApkMetadata(good.replace('app.prism.launcher', 'app.prism.debug'), v));
  assert.throws(() => verifyApkMetadata(good + 'application-debuggable\n', v));
});
