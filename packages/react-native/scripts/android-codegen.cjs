const path = require('node:path');
const fs = require('node:fs');
const {createRequire} = require('node:module');

// 依赖目录由宿主或 CI 显式提供，不引用开发机工作区。
const [nodeModules, output] = process.argv.slice(2);
if (!nodeModules || !output) throw new Error('需要 node_modules 与输出目录');
const fromTooling = createRequire(path.join(path.resolve(nodeModules), 'react-native/package.json'));
const combine = fromTooling('@react-native/codegen/lib/cli/combine/combine-js-to-schema.js');
const executor = require(path.join(path.resolve(nodeModules), 'react-native/scripts/codegen/generate-specs-cli-executor.js'));
fs.mkdirSync(output, {recursive: true});
const schema = path.join(output, 'schema.json');
combine.combineSchemasInFileListAndWriteToFile(
  [path.resolve(__dirname, '../src/specs/NativeUnifiedBridge.ts')],
  'android', schema, null, 'NativeUnifiedBridgeSpec',
);
executor.execute('android', schema, output, 'NativeUnifiedBridgeSpec',
  'com.aeris.sdk.reactnative.codegen', 'modules');
