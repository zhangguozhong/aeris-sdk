#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outputIndex = process.argv.indexOf('--output');
const output = path.resolve(
  outputIndex >= 0 ? process.argv[outputIndex + 1] : path.join(root, 'artifacts/android-maven'),
);
const modules = [
  'aeris',
  'aeris-react-native',
  'aeris-web',
  'aeris-flutter',
  'aeris-unity',
  'aeris-unity-channel',
];
if (fs.existsSync(output))
  throw new Error('候选目录已存在；请显式选择新的 --output，不能覆盖旧验收证据');
fs.mkdirSync(output, { recursive: true });
// Gradle 只写本地 Maven 目录；脚本不配置远程发布仓库和凭据。
execFileSync(
  path.join(root, 'native/android/gradlew'),
  [
    ...modules.map((name) => `:${name}:publishReleasePublicationToAerisStagingRepository`),
    `-PaerisMavenStagingDir=${output}`,
    '--no-daemon',
    '--console=plain',
  ],
  { cwd: path.join(root, 'native/android'), stdio: 'inherit' },
);
const files = [];
for (const name of modules) {
  const directory = path.join(output, 'com/aeris/sdk', name, '0.26.0-preview.1');
  const base = `${name}-0.26.0-preview.1`;
  for (const suffix of [name === 'aeris-unity-channel' ? '.jar' : '.aar', '-sources.jar', '.pom']) {
    const filename = path.join(directory, base + suffix);
    const bytes = fs.readFileSync(filename);
    if (!bytes.length) throw new Error(`候选制品为空 ${filename}`);
    if (suffix === '.pom') {
      const xml = bytes.toString('utf8');
      for (const expected of [
        '<groupId>com.aeris.sdk</groupId>',
        `<artifactId>${name}</artifactId>`,
        '<version>0.26.0-preview.1</version>',
      ]) {
        if (!xml.includes(expected)) throw new Error(`POM 身份不匹配 ${filename}`);
      }
      if (/<version>[^<]*(?:\+|LATEST|RELEASE|\[|\()/i.test(xml))
        throw new Error(`POM 包含动态依赖 ${filename}`);
    } else {
      const entries = execFileSync('unzip', ['-Z1', filename], { encoding: 'utf8' })
        .trim()
        .split('\n');
      if (suffix === '.aar') {
        for (const required of ['AndroidManifest.xml', 'classes.jar', 'proguard.txt'])
          if (!entries.includes(required)) throw new Error(`AAR 缺失 ${required}: ${name}`);
      }
      if (suffix === '-sources.jar' && !entries.some((entry) => /\.(?:kt|java)$/.test(entry)))
        throw new Error(`sources.jar 缺少源码 ${name}`);
    }
    files.push({
      path: path.relative(output, filename),
      bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
    });
  }
}
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const dirty =
  execFileSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' }).trim() !== '';
fs.writeFileSync(
  path.join(output, 'candidate-manifest.json'),
  JSON.stringify(
    { schemaVersion: 1, candidateOnly: true, remotePublished: false, commit, dirty, files },
    null,
    2,
  ) + '\n',
);
console.log(
  JSON.stringify({ output, artifacts: files.length, remotePublished: false, dirty }, null, 2),
);
