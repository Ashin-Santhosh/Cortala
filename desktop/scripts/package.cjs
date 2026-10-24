'use strict';
const { packager } = require('@electron/packager');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const root = path.resolve(__dirname, '..');
const [platform, arch] = process.argv.slice(2);
if (!['win32', 'linux'].includes(platform) || arch !== 'x64') throw new Error('Supported targets: win32 x64 or linux x64');
const runtime = path.join(root, 'runtime', `${platform}-${arch}`);
const extension = platform === 'win32' ? '.exe' : '';
for (const file of ['justwhisper-live', 'whisper-cli']) {
  if (!fs.statSync(path.join(runtime, file + extension), { throwIfNoEntry: false })?.isFile()) {
    throw new Error(`Build the ${platform} native runtime before packaging (${file}).`);
  }
  const bytes = fs.readFileSync(path.join(runtime, file + extension));
  if (platform === 'linux' ? bytes.subarray(0, 4).toString('hex') !== '7f454c46' : bytes.subarray(0, 2).toString() !== 'MZ') {
    throw new Error(`Wrong executable format for ${platform}: ${file}`);
  }
}
if (!fs.existsSync(path.join(runtime, 'licenses', 'whisper.cpp-LICENSE'))) {
  throw new Error('Native runtime publisher license is missing.');
}
(async () => {
  const output = await packager({
    dir: root, name: 'JustWhisper', platform, arch,
    electronVersion: require('../package.json').devDependencies.electron,
    out: path.join(root, 'release'), overwrite: true, asar: true,
    extraResource: [runtime],
    ignore: [/^\/release($|\/)/, /^\/runtime($|\/)/, /^\/test($|\/)/, /^\/native($|\/)/, /^\/scripts($|\/)/],
    prune: true,
  });
  for (const directory of output) {
    const bundled = path.join(directory, 'resources', `${platform}-${arch}`);
    const files = ['justwhisper-live' + extension, 'whisper-cli' + extension, 'licenses/whisper.cpp-LICENSE'];
    const manifest = files.map(file => ({ file, sha256: createHash('sha256').update(fs.readFileSync(path.join(bundled, file))).digest('hex') }));
    fs.writeFileSync(path.join(bundled, 'manifest.json'), JSON.stringify({ platform, arch, whisperVersion: '1.9.4', files: manifest }, null, 2) + '\n');
    console.log(directory);
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
