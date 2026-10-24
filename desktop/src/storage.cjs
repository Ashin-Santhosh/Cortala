'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { defaults, endpoint } = require('./validation.cjs');
function emptyLibrary() { return { version: 1, prefs: defaults(), history: [], modes: [{ id: randomUUID(), name: 'Dictation', instruction: '' }], vocabulary: [], snippets: [], workflows: [], credentials: {} }; }
function originKey(kind, value) { return `${kind}:${endpoint(value).origin}`; }
class EncryptedLibrary {
  constructor(directory, safeStorage, platform = process.platform) { this.directory = directory; this.safeStorage = safeStorage; this.platform = platform; this.file = path.join(directory, 'library.vault'); this.state = emptyLibrary(); this.status = { persistent: false, detail: 'Checking secure storage…' }; this.blocked = false; this.writeQueue = Promise.resolve(); }
  secure() {
    try { return this.safeStorage.isEncryptionAvailable() && !(this.platform === 'linux' && this.safeStorage.getSelectedStorageBackend?.() === 'basic_text'); } catch { return false; }
  }
  async secureAvailable() {
    try {
      const method = this.safeStorage.isAsyncEncryptionAvailable || this.safeStorage.isEncryptionAvailableAsync;
      const available = typeof method === 'function' ? await method.call(this.safeStorage) : this.safeStorage.isEncryptionAvailable();
      const backend = this.safeStorage.getSelectedStorageBackend?.();
      return available && !(this.platform === 'linux' && !['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6'].includes(backend));
    } catch { return false; }
  }
  async crypto(operation, value) {
    const asyncMethod = this.safeStorage[`${operation}StringAsync`];
    if (typeof asyncMethod === 'function') {
      const result = await asyncMethod.call(this.safeStorage, value);
      return result && typeof result === 'object' && 'result' in result ? result.result : result;
    }
    return this.safeStorage[`${operation}String`](value);
  }
  async load() {
    const secure = await this.secureAvailable();
    this.status = { persistent: secure, detail: secure ? 'Library and origin-bound API keys encrypted with this OS keychain.' : 'Secure keychain unavailable. Changes and API keys stay in memory; retained recovery audio still uses private local files.' };
    let data; try { data = await fs.readFile(this.file); } catch (error) { if (error.code !== 'ENOENT') throw error; return this.state; }
    if (!secure) { this.blocked = true; this.status.detail = 'Saved encrypted library is locked. It is preserved; this session is memory-only.'; return this.state; }
    try {
      if (data.length > 20 * 1024 * 1024) throw new Error('Library exceeds its storage bound');
      const value = JSON.parse(await this.crypto('decrypt', data));
      if (value.version !== 1 || !Array.isArray(value.history) || !value.prefs || typeof value.credentials !== 'object') throw new Error('Invalid encrypted library');
      this.state = { ...emptyLibrary(), ...value, prefs: { ...defaults(), ...value.prefs } };
    } catch {
      this.blocked = true; this.status = { persistent: false, detail: 'Saved encrypted library could not be unlocked. Its original bytes are preserved; this session is memory-only.' };
    }
    return this.state;
  }
  key(kind, endpointURL) { return this.state.credentials[originKey(kind, endpointURL)] || ''; }
  setKey(kind, endpointURL, value) { const key = originKey(kind, endpointURL); if (value) this.state.credentials[key] = value; else delete this.state.credentials[key]; }
  async save() {
    if (!(await this.secureAvailable()) || this.blocked) { this.status.persistent = false; return false; }
    const json = JSON.stringify(this.state); if (Buffer.byteLength(json) > 15 * 1024 * 1024) throw new Error('Library limit reached; export older transcripts before continuing');
    const task = async () => {
      await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
      const encrypted = await this.crypto('encrypt', json);
      const temporary = `${this.file}.${randomUUID()}.tmp`;
      try { await fs.writeFile(temporary, encrypted, { mode: 0o600, flag: 'wx' }); await fs.rename(temporary, this.file); }
      finally { await fs.rm(temporary, { force: true }).catch(() => {}); }
      return true;
    };
    const pending = this.writeQueue.then(task); this.writeQueue = pending.catch(() => {}); return pending;
  }
  snapshot() {
    const { credentials, ...state } = this.state;
    return structuredClone({ ...state, history: state.history.map(({ audioPath, ...entry }) => ({ ...entry, audioAvailable: !!audioPath })), prefs: { ...state.prefs, speechKeySaved: !!this.key('speech', state.prefs.speechEndpoint), rewriteKeySaved: !!this.key('rewrite', state.prefs.rewriteEndpoint) } });
  }
}
module.exports = { EncryptedLibrary, emptyLibrary, originKey };
