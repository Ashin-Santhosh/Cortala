'use strict';
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const { StringDecoder } = require('node:string_decoder');
const RATE = 16000, WINDOW = RATE * 12, MAX_SAMPLES = RATE * 60 * 60 * 2;
function cleanEnvironment(source = process.env) { return Object.fromEntries(Object.entries(source).filter(([key]) => !/^(DYLD_|GGML_|LD_PRELOAD$|LD_LIBRARY_PATH$|NODE_OPTIONS$|ELECTRON_RUN_AS_NODE$)/.test(key))); }
function wavHeader(samples) {
  const b = Buffer.alloc(44); b.write('RIFF', 0); b.writeUInt32LE(36 + samples * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(RATE, 24); b.writeUInt32LE(RATE * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(samples * 2, 40); return b;
}
class PCMRecording {
  constructor(directory) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 }); this.path = path.join(directory, `${randomUUID()}.wav`);
    this.fd = fs.openSync(this.path, 'wx', 0o600); fs.writeSync(this.fd, wavHeader(0)); this.ring = new Float32Array(WINDOW); this.total = 0; this.peak = 0; this.silent = true; this.closed = false;
  }
  append(value) {
    if (this.closed || !(value instanceof Float32Array) || value.length < 1 || value.length > 32000 || this.total + value.length > MAX_SAMPLES) throw new Error('Invalid audio chunk or two-hour recording limit reached');
    if (!value.every(Number.isFinite)) throw new Error('Audio samples must be finite');
    const pcm = Buffer.alloc(value.length * 2); let energy = 0;
    for (let i = 0; i < value.length; i++) { const sample = Math.max(-1, Math.min(1, value[i])); this.ring[(this.total + i) % WINDOW] = sample; pcm.writeInt16LE(Math.round(sample * 32767), i * 2); energy += sample * sample; if (Math.abs(sample) > 0.00001) this.silent = false; }
    fs.writeSync(this.fd, pcm); this.total += value.length; fs.writeSync(this.fd, wavHeader(this.total), 0, 44, 0); this.peak = Math.min(1, Math.sqrt(energy / value.length) * 3);
  }
  snapshot() { const count = Math.min(this.total, WINDOW), pcm = new Float32Array(count); for (let i = 0; i < count; i++) pcm[i] = this.ring[(this.total - count + i) % WINDOW]; return { pcm, start: (this.total - count) / RATE, end: this.total / RATE }; }
  close() { if (!this.closed) { fs.writeSync(this.fd, wavHeader(this.total), 0, 44, 0); fs.fsyncSync(this.fd); fs.closeSync(this.fd); this.closed = true; } return this.path; }
  async discard() { this.close(); await fsp.rm(this.path, { force: true }); }
}
function norm(value) { return value.toLowerCase().replace(/[^\p{L}\p{N}]/gu, ''); }
class WindowAccumulator {
  constructor() { this.committed = []; this.recent = []; this.start = 0; this.end = 0; this.complete = true; this.truncated = false; }
  update(words, start, end) {
    if (!Array.isArray(words) || words.length > 2048 || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < this.end) throw new Error('Invalid live decoder response');
    if (start > this.end + 0.25) this.complete = false;
    let incoming = words.filter(w => Number.isFinite(w.start) && Number.isFinite(w.end) && w.start >= 0 && w.end > w.start && w.end <= end - start + 0.5 && typeof w.text === 'string' && w.text.trim() && w.text.length <= 2000).map(w => ({ start: w.start + start, end: w.end + start, text: w.text.trim() }));
    if (start > this.start) {
      const candidates = this.recent.filter(w => w.end <= start + 2);
      if (candidates.length) {
        let match = -1;
        outer: for (let length = Math.min(12, candidates.length, incoming.length); length > 0; length--) {
          const suffix = candidates.slice(-length);
          for (let offset = 0; offset <= Math.min(12, incoming.length - length); offset++) {
            if (suffix.every((w, i) => norm(w.text) === norm(incoming[offset + i].text)) && Math.abs(suffix.at(-1).end - incoming[offset + length - 1].end) < 2) { match = offset + length; break outer; }
          }
        }
        this.committed.push(...candidates);
        if (match >= 0) incoming = incoming.slice(match);
        else { this.complete = false; incoming = incoming.filter(w => w.end > this.committed.at(-1).end); }
      }
    }
    this.recent = incoming; this.start = start; this.end = end;
    while (this.committed.length > 3000 || this.committed.reduce((n, w) => n + w.text.length, 0) > 40000) { this.committed.shift(); this.truncated = true; }
  }
  get text() { return [...this.committed, ...this.recent].map(w => w.text).join(' ').trim(); }
  final(end) { if (!this.complete || this.truncated || Math.abs(this.end - end) > 0.15) throw new Error('Live coverage incomplete; completing the saved audio locally'); return this.text; }
}
class ResidentWhisper extends EventEmitter {
  constructor(spawnProcess = spawn) { super(); this.spawn = spawnProcess; this.child = null; this.identity = ''; this.pending = null; this.buffer = ''; this.phase = 'released'; this.detail = 'Local model not loaded'; this.warming = null; }
  status() { return { phase: this.phase, detail: this.detail }; }
  setStatus(phase, detail) { this.phase = phase; this.detail = detail; this.emit('state', this.status()); }
  async warm(executable, model, language) {
    const identity = JSON.stringify([executable, model, language]);
    if (this.child && this.identity === identity) { if (this.warming) await this.warming; return; }
    this.release(); if (!path.isAbsolute(executable) || !path.isAbsolute(model)) throw new Error('Choose an installed local helper and GGML model');
    this.identity = identity; this.setStatus('warming', 'Loading local Whisper; first GPU initialization can take longer.');
    const decoder = new StringDecoder('utf8');
    const child = this.spawn(executable, [model, language || 'auto'], { shell: false, windowsHide: true, env: cleanEnvironment(), stdio: ['pipe', 'pipe', 'ignore'] }); this.child = child;
    child.stdout.on('data', chunk => {
      if (this.child !== child) return;
      this.buffer += decoder.write(chunk); if (Buffer.byteLength(this.buffer) > 262144) return this.fail(new Error('Local helper response limit exceeded'));
      let newline;
      while ((newline = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
        const pending = this.pending; this.pending = null;
        if (!pending) return this.fail(new Error('Unexpected local helper output'));
        clearTimeout(pending.timer); try { pending.resolve(JSON.parse(line)); } catch { pending.reject(new Error('Invalid local helper response')); this.release(); }
      }
    });
    child.on('error', () => { if (this.child === child) this.fail(new Error('Could not launch the selected local helper')); });
    child.on('exit', () => { if (this.child === child) this.fail(new Error('Local helper stopped. Saved audio remains available for recovery.')); });
    child.stdin.on('error', () => { if (this.child === child) this.fail(new Error('Local helper input closed')); });
    const began = performance.now();
    this.warming = this.wait(120000).then(reply => {
      if (this.child !== child) throw new Error('Model load superseded');
      if (!reply.ready || reply.protocol !== 1) throw new Error('Unsupported local helper protocol');
      this.setStatus('ready', `Model resident · loaded in ${((performance.now() - began) / 1000).toFixed(2)}s`);
    });
    try { await this.warming; } catch (error) { if (this.child === child) this.fail(error); throw error; } finally { if (this.child === child) this.warming = null; }
  }
  wait(timeout) {
    if (this.pending) throw new Error('Local helper already has an inference in flight');
    return new Promise((resolve, reject) => { this.pending = { resolve, reject, timer: setTimeout(() => this.fail(new Error('Local helper timed out; recover from the saved recording')), timeout) }; });
  }
  async infer(samples) {
    if (!this.child || this.phase !== 'ready' || samples.length < 1600 || samples.length > WINDOW || !samples.every(Number.isFinite)) throw new Error('Local live model is not ready or audio is invalid');
    const frame = Buffer.alloc(4 + samples.length * 4); frame.writeUInt32LE(samples.length); for (let i = 0; i < samples.length; i++) frame.writeFloatLE(samples[i], 4 + i * 4);
    const pending = this.wait(45000); this.child.stdin.write(frame);
    const result = await pending; if (!Array.isArray(result.segments)) throw new Error('Invalid local segments'); return result.segments;
  }
  fail(error) { const pending = this.pending; this.pending = null; if (pending) { clearTimeout(pending.timer); pending.reject(error); } this.release(); this.setStatus('error', error.message); }
  release() { const child = this.child; this.child = null; this.identity = ''; this.buffer = ''; this.warming = null; if (this.pending) { clearTimeout(this.pending.timer); this.pending.reject(new Error('Local model released')); this.pending = null; } child?.kill(); this.setStatus('released', 'Local model released'); }
}
module.exports = { RATE, WINDOW, MAX_SAMPLES, PCMRecording, WindowAccumulator, ResidentWhisper, wavHeader, cleanEnvironment };
