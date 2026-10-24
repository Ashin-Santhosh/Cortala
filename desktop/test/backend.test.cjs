'use strict';
const test = require('node:test'); const assert = require('node:assert/strict');
const fs = require('node:fs/promises'); const os = require('node:os'); const path = require('node:path'); const { randomUUID } = require('node:crypto'); const { EventEmitter } = require('node:events');
const v = require('../src/validation.cjs'); const { validateSender, validateInvocation } = require('../src/security.cjs');
const { EncryptedLibrary } = require('../src/storage.cjs'); const { PCMRecording, WindowAccumulator, ResidentWhisper, cleanEnvironment } = require('../src/capture.cjs'); const { requestJSON, rewrite, transform } = require('../src/providers.cjs'); const { runWorkflow } = require('../src/workflows.cjs'); const { DesktopEngine } = require('../src/engine.cjs');
const workflow = () => ({ id: randomUUID(), name: 'Research', phrase: 'begin research', enabled: true, actions: [{ id: randomUUID(), kind: 'openURL', value: 'https://example.com' }, { id: randomUUID(), kind: 'delay', value: '1' }] });
async function temporary(t) { const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'justwhisper-desktop-test-')); t.after(() => fs.rm(dir, { recursive: true, force: true })); return dir; }
function secureStorage() { return { isEncryptionAvailable: () => true, getSelectedStorageBackend: () => 'gnome_libsecret', encryptStringAsync: async value => Buffer.from('encrypted:' + value), decryptStringAsync: async value => ({ result: value.toString().replace(/^encrypted:/, ''), shouldReEncrypt: false }) }; }
class FakeWorker extends EventEmitter { constructor() { super(); this.calls = 0; this.releases = 0; } status() { return { phase: 'ready', detail: 'fake' }; } async warm() {} async infer() { this.calls++; return [{ start: 0, end: 1, text: 'begin research' }]; } release() { this.releases++; } }
test('workflow sharing bounded/versioned; imports disable and replace all identities', () => {
  const original = workflow(), imported = v.importWorkflow(v.exportWorkflow(original)); assert.equal(imported.enabled, false); assert.notEqual(imported.id, original.id); assert.notEqual(imported.actions[0].id, original.actions[0].id);
  for (const value of ['file:///tmp/private', 'javascript:alert(1)', 'https://user:secret@example.com', 'https://example.com/?token=secret']) { const unsafe = workflow(); unsafe.actions[0].value = value; assert.throws(() => v.workflow(unsafe)); }
  const unsupported = workflow(); unsupported.actions[0].kind = 'shell'; assert.throws(() => v.workflow(unsupported));
  assert.throws(() => v.importWorkflow(JSON.stringify({ version: 2, workflow: original })));
  assert.throws(() => v.importWorkflow(' '.repeat(65537)));
  const tooLong = workflow(); tooLong.actions = Array.from({ length: 3 }, () => ({ id: randomUUID(), kind: 'delay', value: '30' })); assert.throws(() => v.workflow(tooLong));
  const app = workflow(); app.actions[0] = { id: randomUUID(), kind: 'openApp', value: 'C:\\Windows\\cmd.exe' }; assert.throws(() => v.workflow(app));
});
test('only one exact enabled command matches, not ordinary phrase-containing text', () => { const w = workflow(); assert.equal(v.matchWorkflow('BEGIN RESEARCH!', [w]), w); assert.equal(v.matchWorkflow('please begin research', [w]), null); assert.equal(v.matchWorkflow(w.phrase, [w, w]), null); w.enabled = false; assert.equal(v.matchWorkflow(w.phrase, [w]), null); });
test('fake workflow adapters keep order and stop on failure/cancellation', async () => {
  const values = []; const w = workflow(); await runWorkflow(w, { openURL: async url => values.push(url), delay: async () => values.push('wait') }); assert.deepEqual(values, ['https://example.com/', 'wait']);
  values.length = 0; await assert.rejects(runWorkflow(w, { openURL: async () => { throw new Error('expected'); }, delay: async () => values.push('bad') })); assert.equal(values.length, 0);
  const controller = new AbortController(); controller.abort(); await assert.rejects(runWorkflow(w, {}, controller.signal));
});
test('async encrypted storage unwraps Electron decrypt result and snapshots omit every key', async t => {
  const dir = await temporary(t), storage = new EncryptedLibrary(dir, secureStorage(), 'linux'); await storage.load(); storage.setKey('speech', 'https://api.example.com/v1/audio', 'private-key'); await storage.save();
  const restored = new EncryptedLibrary(dir, secureStorage(), 'linux'); await restored.load(); assert.equal(restored.key('speech', 'https://api.example.com/other'), 'private-key'); assert.equal(restored.key('speech', 'https://other.example.com'), ''); assert.equal(restored.key('speech', 'http://localhost:1234'), '');
  assert.equal(JSON.stringify(restored.snapshot()).includes('private-key'), false); assert.equal('credentials' in restored.snapshot(), false); assert.equal(restored.snapshot().prefs.speechKeySaved, false);
});
test('Linux basic_text never writes library or keys, sync encrypted fallback remains supported', async t => {
  const dir = await temporary(t), unsafe = secureStorage(); unsafe.getSelectedStorageBackend = () => 'basic_text'; const storage = new EncryptedLibrary(dir, unsafe, 'linux'); await storage.load(); storage.setKey('speech', 'https://example.com', 'secret'); assert.equal(await storage.save(), false); await assert.rejects(fs.stat(storage.file), { code: 'ENOENT' });
  const synchronous = { isEncryptionAvailable: () => true, encryptString: text => Buffer.from(text), decryptString: data => data.toString() }; const fallback = new EncryptedLibrary(dir, synchronous, 'win32'); await fallback.load(); assert.equal(await fallback.save(), true); const again = new EncryptedLibrary(dir, synchronous, 'win32'); await again.load(); assert.equal(again.blocked, false);
});
test('failed decrypt preserves original vault bytes and blocks overwrites', async t => {
  const dir = await temporary(t); await fs.writeFile(path.join(dir, 'library.vault'), 'damaged encrypted bytes'); const safe = secureStorage(); safe.decryptStringAsync = async () => { throw new Error('locked'); }; const library = new EncryptedLibrary(dir, safe); await library.load(); assert.equal(library.blocked, true); assert.equal(await library.save(), false); assert.equal(await fs.readFile(library.file, 'utf8'), 'damaged encrypted bytes');
});
test('WAV writer and ring remain bounded; crash header and final header describe complete PCM', async t => {
  const dir = await temporary(t), recording = new PCMRecording(dir); const samples = new Float32Array(16000).fill(0.1); for (let i = 0; i < 15; i++) recording.append(samples);
  assert.equal(recording.snapshot().pcm.length, 192000); assert.equal(recording.snapshot().start, 3); assert.equal(recording.silent, false); assert.throws(() => recording.append(new Float32Array([NaN]))); assert.throws(() => recording.append(new Float32Array(32001)));
  let bytes = await fs.readFile(recording.path); assert.equal(bytes.readUInt32LE(40), 15 * 32000); recording.close(); bytes = await fs.readFile(recording.path); assert.equal(bytes.length, 44 + 15 * 32000); assert.equal(bytes.readUInt32LE(4), bytes.length - 8);
});
test('overlapping live windows replace revisions and require full audio after gaps', () => {
  const a = new WindowAccumulator(); a.update([{ start: 0, end: 1, text: 'hello' }, { start: 1, end: 2, text: 'wrong' }], 0, 3); a.update([{ start: 0, end: 1, text: 'hello' }, { start: 1, end: 2, text: 'world' }], 0, 4); assert.equal(a.text, 'hello world');
  a.update([{ start: 0, end: 1, text: 'world' }, { start: 1, end: 2, text: 'today' }], 1, 5); assert.equal(a.final(5), 'hello world today');
  a.update([{ start: 0, end: 1, text: 'later' }], 20, 22); assert.throws(() => a.final(22));
});
test('public 44-second repeated JFK window replay has no duplicate hypotheses', async () => {
  const report = JSON.parse(await fs.readFile(path.join(__dirname, '../../benchmarks/results/live-jfk-base.json'), 'utf8')); const a = new WindowAccumulator(); for (const w of report.warm_windows) a.update(w.segments, w.start, w.end);
  const normalized = a.final(report.warm_windows.at(-1).end).toLowerCase().match(/[\p{L}\p{N}]+/gu).join(' '); const reference = Array(4).fill('and so my fellow americans ask not what your country can do for you ask what you can do for your country').join(' '); assert.equal(normalized, reference);
});
test('HTTP never forwards audio or credentials across origin redirects and bounds response', async () => {
  const requests = []; const fake = async (url, options) => { requests.push([url, options]); return new Response(null, { status: 307, headers: { location: 'https://other.example.com/asr' } }); };
  await assert.rejects(requestJSON('https://example.com/asr', { method: 'POST', headers: { Authorization: 'Bearer private' }, body: 'audio' }, fake), /Cross-origin/); assert.equal(requests.length, 1); assert.equal(requests[0][1].redirect, 'manual');
  await assert.rejects(requestJSON('https://example.com', {}, async () => new Response('x'.repeat(4 * 1024 * 1024 + 1))), /limit/);
});
test('Ollama rewrite explicitly disables thinking and keeps transcript as data', async () => {
  let payload; const result = await rewrite('source text', 'Clean punctuation', { rewriteEndpoint: 'http://localhost:11434/api/chat', rewriteModel: 'local-model' }, '', undefined, async (_url, options) => { payload = JSON.parse(options.body); return new Response(JSON.stringify({ message: { content: 'clean text' } })); }); assert.equal(result, 'clean text'); assert.equal(payload.think, false); assert.equal(payload.stream, false); assert.equal(payload.messages[1].content, 'source text');
  assert.equal(transform('a.b hello', [{ phrase: 'a.b', replacement: 'literal$&' }], [{ trigger: 'hello', text: 'snippet' }]), 'literal$& snippet');
});
async function makeEngine(t) {
  const dir = await temporary(t), library = new EncryptedLibrary(dir, secureStorage(), 'linux'); await library.load(); library.state.prefs.localModel = '/fake/model'; library.state.prefs.liveExecutable = '/fake/helper'; library.state.prefs.localExecutable = '/fake/cli'; library.state.prefs.warmModel = false;
  const opened = [], worker = new FakeWorker(); const provider = { localTranscribe: async () => 'begin research', cloudTranscribe: async () => { throw new Error('Unexpected cloud upload'); }, transform, rewrite: async text => text };
  const engine = new DesktopEngine({ library, directory: dir, worker, provider, adapters: { openURL: async url => opened.push(url), delay: async () => {} } }); library.state.workflows = [workflow()]; return { engine, library, opened, worker, provider };
}
test('dictation never runs a matching workflow; command does; retry never repeats command actions', async t => {
  const { engine, opened } = await makeEngine(t); await engine.start('dictation'); engine.captureReady(); engine.pushPCM(new Float32Array(16000).fill(0.1)); await engine.stop(); assert.equal(opened.length, 0); assert.equal(engine.lastResult.text, 'begin research');
  await engine.start('command'); engine.captureReady(); engine.pushPCM(new Float32Array(16000).fill(0.1)); await engine.stop(); assert.equal(opened.length, 1); await engine.retry(engine.state.history[0].id); assert.equal(opened.length, 1);
});
test('silent capture is a no-op and failed local ASR preserves saved audio without cloud fallback', async t => {
  const { engine, provider, worker } = await makeEngine(t); await engine.start('dictation'); engine.captureReady(); engine.pushPCM(new Float32Array(16000)); await engine.stop(); assert.equal(engine.state.history.length, 0);
  worker.warm = async () => { throw new Error('No live helper'); }; provider.localTranscribe = async () => { throw new Error('Local ASR failed'); };
  await engine.start('dictation'); engine.captureReady(); engine.pushPCM(new Float32Array(16000).fill(0.2)); await engine.stop(); assert.equal(engine.state.history.length, 1); assert.equal(engine.state.history[0].raw, ''); assert.equal((await fs.stat(engine.state.history[0].audioPath)).isFile(), true); assert.equal(engine.capture.state, 'idle');
});
test('late recognition cannot publish into a cancelled or new capture; only one inference in flight', async t => {
  const { engine, worker } = await makeEngine(t); let finish; worker.infer = () => new Promise(resolve => { finish = resolve; }); await engine.start(); engine.captureReady(); engine.pushPCM(new Float32Array(16000).fill(0.1)); engine.pushPCM(new Float32Array(16000).fill(0.1)); await engine.cancel(); finish([{ start: 0, end: 1, text: 'stale secret' }]); await new Promise(resolve => setImmediate(resolve)); assert.equal(engine.capture.partial, ''); assert.equal(engine.state.history.length, 0); assert.equal(worker.releases, 1);
});
test('environment strips runtime injection variables', () => { const environment = cleanEnvironment({ PATH: '/usr/bin', DYLD_INSERT_LIBRARIES: 'bad', GGML_BACKEND_PATH: 'bad', NODE_OPTIONS: '--require bad', LD_PRELOAD: 'bad' }); assert.deepEqual(environment, { PATH: '/usr/bin' }); });

test('IPC requires the exact local main frame and validated arity, never a sibling or subframe', () => {
  const frame = { url: 'file:///ui/index.html' }, webContents = { mainFrame: frame }, window = { webContents, isDestroyed: () => false };
  validateSender({ sender: webContents, senderFrame: frame }, window, frame.url);
  assert.throws(() => validateSender({ sender: webContents, senderFrame: { url: frame.url } }, window, frame.url));
  assert.throws(() => validateSender({ sender: {}, senderFrame: frame }, window, frame.url));
  assert.throws(() => validateSender({ sender: webContents, senderFrame: frame }, window, 'https://attacker.example'));
  assert.throws(() => validateInvocation('__proto__', [])); assert.throws(() => validateInvocation('copy', [])); assert.throws(() => validateInvocation('getState', ['unexpected'])); validateInvocation('saveCollection', ['modes', []]);
});
test('Electron45 async availability is initialized before checking encryption support', async t => {
  const dir = await temporary(t), safe = secureStorage(); let initialized = false;
  safe.isAsyncEncryptionAvailable = async () => { initialized = true; return true; }; safe.isEncryptionAvailable = () => false;
  const library = new EncryptedLibrary(dir, safe, 'linux'); await library.load(); assert.equal(initialized, true); assert.equal(library.status.persistent, true); assert.equal(await library.save(), true);
});
