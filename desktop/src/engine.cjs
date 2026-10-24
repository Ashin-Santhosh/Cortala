'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { EventEmitter } = require('node:events');
const { PCMRecording, ResidentWhisper, WindowAccumulator } = require('./capture.cjs');
const validation = require('./validation.cjs');
const providers = require('./providers.cjs');
const workflows = require('./workflows.cjs');
class DesktopEngine extends EventEmitter {
  constructor({ library, directory, platform = process.platform, runtimeDirectory, worker, provider = providers, adapters }) {
    super(); this.library = library; this.directory = directory; this.audioDirectory = path.join(directory, 'Recordings'); this.platform = platform; this.runtimeDirectory = runtimeDirectory; this.worker = worker || new ResidentWhisper(); this.provider = provider; this.adapters = adapters;
    this.capture = { state: 'idle', duration: 0, level: 0, partial: '', kind: 'dictation' }; this.errors = []; this.lastResult = { text: '', copyFallback: true }; this.operation = 0; this.running = null; this.recording = null; this.liveTask = null; this.lastWindow = 0; this.previewFailed = false; this.controller = null; this.worker.on?.('state', () => this.publish());
  }
  get state() { return this.library.state; }
  snapshot() { return { ...this.library.snapshot(), platform: this.platform, version: '0.3.0-alpha.1', capabilities: { autoPaste: false, systemAudio: false, diarization: false, windowPlacement: false, liveTranslation: false }, errors: this.errors, storage: this.library.status, model: this.worker.status(), capture: { ...this.capture }, lastResult: { ...this.lastResult } }; }
  publish() { this.emit('state', this.snapshot()); }
  report(error) { const message = typeof error === 'string' ? error : error.message || 'The action failed'; this.errors.push({ id: randomUUID(), date: new Date().toISOString(), message: message.slice(0, 1000) }); this.errors = this.errors.slice(-20); this.publish(); }
  async persist() { try { await this.library.save(); } catch (error) { this.report(error); } }
  async initialize() { await this.library.load(); this.publish(); if (this.state.prefs.warmModel && this.state.prefs.localModel) void this.warmModel().catch(error => this.report(error)); }
  runtime(name) { const file = this.platform === 'win32' ? name + '.exe' : name; return this.runtimeDirectory ? path.join(this.runtimeDirectory, file) : ''; }
  prefs() { const prefs = { ...this.state.prefs }; prefs.liveExecutable ||= this.runtime('justwhisper-live'); prefs.localExecutable ||= this.runtime('whisper-cli'); return prefs; }
  busy() { return this.capture.state !== 'idle' || !!this.running; }
  async warmModel() { const prefs = this.prefs(); if (!prefs.localModel || !prefs.liveExecutable) throw new Error('Choose a local GGML model and live helper. Models are not downloaded automatically.'); await this.worker.warm(prefs.liveExecutable, prefs.localModel, prefs.language); this.publish(); }
  releaseModel() { if (this.busy()) throw new Error('Finish recording before releasing the model'); this.worker.release(); this.publish(); }
  async saveSettings(changes) {
    if (this.busy()) throw new Error('Finish the current action before changing settings');
    const next = validation.settings(this.state.prefs, changes);
    if (changes.speechKey) this.library.setKey('speech', next.speechEndpoint, changes.speechKey);
    if (changes.rewriteKey) this.library.setKey('rewrite', next.rewriteEndpoint, changes.rewriteKey);
    if (changes.clearSpeechKey) this.library.setKey('speech', next.speechEndpoint, '');
    if (changes.clearRewriteKey) this.library.setKey('rewrite', next.rewriteEndpoint, '');
    const oldIdentity = JSON.stringify([this.state.prefs.localModel, this.state.prefs.liveExecutable, this.state.prefs.language]);
    this.state.prefs = next; await this.persist();
    if (oldIdentity !== JSON.stringify([next.localModel, next.liveExecutable, next.language]) || !next.warmModel) this.worker.release();
    if (next.warmModel && next.localModel) void this.warmModel().catch(error => this.report(error)); this.publish();
  }
  async start(kind = 'dictation') {
    if (!['dictation', 'meeting', 'command'].includes(kind)) throw new Error('Unsupported capture kind');
    if (this.busy()) throw new Error('Finish the current action first');
    const id = ++this.operation; this.controller = new AbortController(); this.capture = { state: 'warming', duration: 0, level: 0, partial: '', kind }; this.previewFailed = false; this.publish();
    try {
      const prefs = this.prefs(); this.sessionPrefs = prefs; this.sessionMode = structuredClone(this.state.modes.find(m => m.id === prefs.selectedModeID) || this.state.modes[0] || { instruction: '', name: 'Dictation' });
      this.sessionVocabulary = structuredClone(this.state.vocabulary); this.sessionSnippets = structuredClone(this.state.snippets);
      this.sessionKeys = { speech: this.library.key('speech', prefs.speechEndpoint), rewrite: this.library.key('rewrite', prefs.rewriteEndpoint) };
      if (prefs.speechProvider === 'local') {
        if (!prefs.localModel) throw new Error('Choose an existing GGML model before recording locally');
        try { await this.worker.warm(prefs.liveExecutable, prefs.localModel, prefs.language); }
        catch (error) { if (!prefs.localExecutable) throw error; this.previewFailed = true; this.report('Live recognition unavailable. Recording will finish with your selected local CLI; no cloud fallback.'); }
      }
      if (id !== this.operation) return;
      this.accumulator = new WindowAccumulator(); this.lastWindow = 0; this.recording = new PCMRecording(this.audioDirectory);
      // Renderer requests mic permission next; captureReady is the only transition
      // to recording. No samples from an earlier renderer session are accepted.
      this.publish();
    } catch (error) { if (id === this.operation) { this.capture.state = 'idle'; this.publish(); } throw error; }
  }
  captureReady() { if (!this.recording || this.capture.state !== 'warming') throw new Error('Capture was not prepared'); this.capture.state = 'recording'; this.publish(); }
  pushPCM(value) {
    if (this.capture.state !== 'recording' || !this.recording) throw new Error('No microphone capture is active');
    this.recording.append(value); this.capture.duration = this.recording.total / 16000; this.capture.level = this.recording.peak;
    if (this.sessionPrefs.speechProvider === 'local' && !this.previewFailed && !this.liveTask && this.recording.total - this.lastWindow >= 16000) {
      const id = this.operation, snapshot = this.recording.snapshot(); this.lastWindow = this.recording.total;
      this.liveTask = this.decodeWindow(snapshot, id).catch(error => { if (id === this.operation) { this.previewFailed = true; this.report(error); } }).finally(() => { if (id === this.operation) this.liveTask = null; });
    }
    this.publish();
  }
  async decodeWindow(snapshot, id) {
    if (snapshot.pcm.length < 1600) return;
    const words = await this.worker.infer(snapshot.pcm);
    if (id !== this.operation) return;
    this.accumulator.update(words, snapshot.start, snapshot.end); this.capture.partial = this.accumulator.text.slice(-12000); this.publish();
  }
  async stop() {
    if (!this.recording || !['warming', 'recording'].includes(this.capture.state)) throw new Error('No recording is active');
    const id = this.operation, recording = this.recording; this.recording = null; recording.close(); this.capture.state = 'processing'; this.capture.level = 0; this.publish();
    const entry = { id: randomUUID(), date: new Date().toISOString(), title: this.capture.kind === 'command' ? 'Voice command — awaiting recognition' : 'Recording — awaiting recognition', raw: '', text: '', duration: recording.total / 16000, isMeeting: this.capture.kind === 'meeting', audioPath: recording.path, forceLocal: this.sessionPrefs.speechProvider === 'local' };
    const kind = this.capture.kind; this.state.history.unshift(entry); this.boundHistory(); await this.persist();
    try {
      await this.liveTask; this.liveTask = null;
      if (id !== this.operation) return;
      if (recording.silent) { this.state.history = this.state.history.filter(h => h.id !== entry.id); await fs.rm(recording.path, { force: true }); await this.persist(); this.capture.state = 'idle'; this.capture.partial = ''; this.publish(); return; }
      let raw;
      if (this.sessionPrefs.speechProvider === 'local' && !this.previewFailed) {
        try { await this.decodeWindow(recording.snapshot(), id); raw = this.accumulator.final(recording.total / 16000); if (!raw.trim()) throw new Error('No final live words'); }
        catch { raw = null; }
      }
      if (id !== this.operation) return;
      await this.processEntry(entry, { prefs: this.sessionPrefs, mode: this.sessionMode, vocabulary: this.sessionVocabulary, snippets: this.sessionSnippets, keys: this.sessionKeys, id, raw, kind });
    } catch (error) { if (id === this.operation) this.report(error); }
    finally { if (id === this.operation) { this.capture.state = 'idle'; this.capture.partial = ''; this.publish(); } }
  }
  async processEntry(entry, context) {
    const { prefs, mode, vocabulary, snippets, keys, id, kind } = context; let raw = context.raw;
    if (raw == null) raw = prefs.speechProvider === 'local' || entry.forceLocal
      ? await this.provider.localTranscribe(entry.audioPath, { ...prefs, speechProvider: 'local' }, vocabulary, this.controller.signal)
      : await this.provider.cloudTranscribe(entry.audioPath, prefs, keys.speech, this.controller.signal);
    if (id !== this.operation) return;
    raw = raw.replace(/\[(BLANK_AUDIO|NO_SPEECH|SILENCE)\]/gi, '').trim();
    entry.raw = raw; entry.text = raw; entry.title = raw ? raw.slice(0, 80) : 'No speech recognized'; await this.persist(); this.publish();
    if (!raw) return;
    if (kind === 'command') {
      const matched = validation.matchWorkflow(raw, this.state.workflows);
      if (matched) await this.executeWorkflow(matched);
      else this.report('No unique enabled workflow matched the exact spoken phrase.');
    } else {
      let output = this.provider.transform(raw, vocabulary, snippets);
      output = await this.provider.rewrite(output, mode.instruction || '', prefs, keys.rewrite, this.controller.signal);
      if (id !== this.operation) return;
      entry.text = output; this.lastResult = { text: output, copyFallback: true };
    }
    if (id !== this.operation) return;
    // Commit text before clearing the recoverable-audio reference. In memory-only
    // mode keep the file: a secure keychain is required for durable history.
    await this.persist();
    if (!prefs.retainAudio && this.library.status.persistent) {
      const audioPath = entry.audioPath; delete entry.audioPath;
      try { const saved = await this.library.save(); if (saved) await fs.rm(audioPath, { force: true }); else entry.audioPath = audioPath; }
      catch (error) { entry.audioPath = audioPath; throw error; }
    }
    this.publish();
  }
  boundHistory() { if (this.state.history.length > 2000) throw new Error('History limit reached. Export and delete older recordings.'); }
  async cancel() {
    ++this.operation; this.controller?.abort(); this.running?.abort(); this.running = null;
    const recording = this.recording; this.recording = null; if (recording) await recording.discard();
    // Termination is needed to interrupt an in-flight inference. A later local
    // session explicitly warms a fresh helper; stale completions cannot publish.
    if (this.liveTask) this.worker.release(); this.liveTask = null;
    this.capture = { state: 'idle', duration: 0, level: 0, partial: '', kind: 'dictation' }; this.publish();
  }
  async importAudio(source) {
    if (this.busy()) throw new Error('Finish the current action first');
    const stat = await fs.stat(source); if (!stat.isFile() || stat.size > 256 * 1024 * 1024 || stat.size < 44) throw new Error('Choose a WAV recording up to 256MiB');
    const handle = await fs.open(source, 'r'); const header = Buffer.alloc(12); try { await handle.read(header, 0, 12, 0); } finally { await handle.close(); }
    if (header.toString('ascii', 0, 4) !== 'RIFF' || header.toString('ascii', 8, 12) !== 'WAVE') throw new Error('This desktop preview imports WAV audio only');
    await fs.mkdir(this.audioDirectory, { recursive: true, mode: 0o700 }); const audioPath = path.join(this.audioDirectory, randomUUID() + '.wav'); await fs.copyFile(source, audioPath); await fs.chmod(audioPath, 0o600);
    const entry = { id: randomUUID(), date: new Date().toISOString(), title: 'Imported audio — awaiting recognition', raw: '', text: '', duration: 0, isMeeting: false, audioPath }; this.state.history.unshift(entry); this.boundHistory(); await this.persist(); await this.retry(entry.id);
  }
  async retry(id) {
    validation.uuid(id); if (this.busy()) throw new Error('Finish the current action first');
    const entry = this.state.history.find(h => h.id === id); if (!entry?.audioPath) throw new Error('No retained audio is available for full reprocessing');
    const operation = ++this.operation; this.controller = new AbortController(); this.capture.state = 'processing'; this.publish();
    const prefs = this.prefs(); if (entry.forceLocal) prefs.speechProvider = 'local';
    try { await this.processEntry(entry, { id: operation, prefs, mode: this.state.modes.find(m => m.id === prefs.selectedModeID) || this.state.modes[0] || {}, vocabulary: this.state.vocabulary, snippets: this.state.snippets, keys: { speech: this.library.key('speech', prefs.speechEndpoint), rewrite: this.library.key('rewrite', prefs.rewriteEndpoint) }, kind: 'dictation' }); }
    catch (error) { this.report(error); } finally { if (this.operation === operation) { this.capture.state = 'idle'; this.publish(); } }
  }
  async deleteTranscript(id) { validation.uuid(id); if (this.busy()) throw new Error('Finish the current action first'); const entry = this.state.history.find(h => h.id === id); if (!entry) return; this.state.history = this.state.history.filter(h => h.id !== id); const saved = await this.library.save(); if (saved && entry.audioPath && path.dirname(entry.audioPath) === this.audioDirectory) await fs.rm(entry.audioPath, { force: true }); this.publish(); }
  async saveCollection(kind, items) { if (this.busy()) throw new Error('Finish the current action first'); const values = validation.collection(kind, items); this.state[kind] = values; await this.persist(); this.publish(); }
  async importWorkflow(json) { if (this.busy()) throw new Error('Finish the current action first'); const value = validation.importWorkflow(json); if (this.state.workflows.length >= 100) throw new Error('Limit: 100 workflows'); this.state.workflows.push(value); await this.persist(); this.publish(); }
  exportWorkflow(id) { validation.uuid(id); const value = this.state.workflows.find(w => w.id === id); if (!value) throw new Error('Workflow not found'); return validation.exportWorkflow(value); }
  async executeWorkflow(value) { this.running = new AbortController(); this.publish(); try { await workflows.runWorkflow(value, this.adapters, this.running.signal); } finally { this.running = null; this.publish(); } }
  async runWorkflow(id) { validation.uuid(id); if (this.busy()) throw new Error('Finish the current action first'); const value = this.state.workflows.find(w => w.id === id); if (!value) throw new Error('Workflow not found'); await this.executeWorkflow(value); }
  async shutdown() {
    ++this.operation; this.controller?.abort(); this.running?.abort(); this.worker.release();
    if (this.recording) { const recording = this.recording; this.recording = null; recording.close(); this.state.history.unshift({ id: randomUUID(), date: new Date().toISOString(), title: 'Recording interrupted — retry available', raw: '', text: '', duration: recording.total / 16000, isMeeting: this.capture.kind === 'meeting', audioPath: recording.path, forceLocal: this.sessionPrefs?.speechProvider === 'local' }); }
    await this.persist();
  }
}
module.exports = { DesktopEngine };
