'use strict';
const { randomUUID } = require('node:crypto');
const MAX_WORKFLOWS = 100;
function fail(message = 'Invalid input') { throw new Error(message); }
function text(value, max = 2000, empty = true) {
  if (typeof value !== 'string' || value.length > max || (!empty && !value.trim()) || value.includes('\0')) fail('Invalid text value');
  return value;
}
function object(value, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !keys.includes(k))) fail('Unsupported fields');
  return value;
}
function httpsURL(value) {
  text(value, 2000, false); let url;
  try { url = new URL(value); } catch { fail('Invalid website URL'); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.search || url.hash) fail('Use HTTPS without credentials, query or fragment');
  return url.href;
}
function endpoint(value) {
  text(value, 2000, false); let url;
  try { url = new URL(value); } catch { fail('Invalid provider endpoint'); }
  if (url.username || url.password || url.hash || !(url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))) fail('Provider must use HTTPS, or HTTP on localhost');
  return url;
}
function normalized(value) { return text(value, 10000).toLocaleLowerCase('en').normalize('NFKC').match(/[\p{L}\p{N}]+/gu)?.join(' ') || ''; }
function uuid(value) { if (typeof value !== 'string' || !/^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i.test(value)) fail('Invalid identity'); return value; }
function workflow(value, imported = false) {
  object(value, ['id', 'name', 'phrase', 'enabled', 'actions']);
  const result = { id: imported ? randomUUID() : uuid(value.id), name: text(value.name, 100, false), phrase: text(value.phrase, 200, false), enabled: imported ? false : value.enabled, actions: [] };
  if (typeof result.enabled !== 'boolean' || !normalized(result.phrase) || !Array.isArray(value.actions) || value.actions.length < 1 || value.actions.length > 20) fail('Workflow requires an exact phrase and 1–20 actions');
  let delay = 0;
  for (const action of value.actions) {
    object(action, ['id', 'kind', 'value']); const item = { id: imported ? randomUUID() : uuid(action.id), kind: action.kind, value: text(action.value, 2000, false) };
    if (item.kind === 'openURL') httpsURL(item.value);
    else if (item.kind === 'webSearch') { /* Text is encoded as one URL query item at execution. */ }
    else if (item.kind === 'openApp') { if (!/^[a-zA-Z\d.-]{1,150}$/.test(item.value)) fail('Use a logical application ID, never an executable path'); }
    else if (item.kind === 'delay') { const seconds = Number(item.value); if (!Number.isFinite(seconds) || seconds < 0 || seconds > 30) fail('Wait must be 0–30 seconds'); delay += seconds; }
    else fail('Unsupported workflow action');
    result.actions.push(item);
  }
  if (delay > 60 || new Set(result.actions.map(x => x.id)).size !== result.actions.length) fail('Invalid workflow bounds');
  return result;
}
function importWorkflow(json) {
  text(json, 65536, false); if (Buffer.byteLength(json) > 65536) fail('Workflow JSON exceeds 64KiB');
  let document; try { document = JSON.parse(json); } catch { fail('Invalid workflow JSON'); }
  object(document, ['version', 'workflow']); if (document.version !== 1) fail('Unsupported workflow version');
  return workflow(document.workflow, true);
}
function exportWorkflow(value) { return JSON.stringify({ version: 1, workflow: workflow(value) }, null, 2); }
function matchWorkflow(phrase, workflows) { const matches = workflows.filter(w => w.enabled && normalized(w.phrase) === normalized(phrase)); return matches.length === 1 ? matches[0] : null; }
function collection(kind, items) {
  if (!Array.isArray(items) || items.length > (kind === 'workflows' ? MAX_WORKFLOWS : 1000)) fail('Collection limit exceeded');
  const result = items.map(item => {
    if (kind === 'workflows') return workflow(item);
    const fields = { modes: ['id', 'name', 'instruction'], vocabulary: ['id', 'phrase', 'replacement'], snippets: ['id', 'trigger', 'text'] }[kind];
    if (!fields) fail('Unsupported collection'); object(item, fields);
    return Object.fromEntries(fields.map(key => [key, key === 'id' ? uuid(item[key]) : text(item[key], key === 'instruction' || key === 'text' ? 10000 : 300, key === 'instruction')]));
  });
  if (new Set(result.map(x => x.id)).size !== result.length) fail('Duplicate identities');
  return result;
}
const defaults = () => ({ speechProvider: 'local', speechEndpoint: 'https://api.openai.com/v1/audio/transcriptions', speechModel: 'whisper-1', language: 'auto', localModel: '', localExecutable: '', liveExecutable: '', rewriteEndpoint: 'http://localhost:11434/api/chat', rewriteModel: '', autoPaste: false, warmModel: true, retainAudio: true, shortcut: 'CommandOrControl+Shift+Space', commandShortcut: 'CommandOrControl+Shift+W', selectedModeID: '' });
function settings(current, changes) {
  object(changes, [...Object.keys(defaults()), 'speechKey', 'rewriteKey', 'clearSpeechKey', 'clearRewriteKey']);
  const next = { ...current };
  for (const [key, value] of Object.entries(changes)) {
    if (['speechKey', 'rewriteKey'].includes(key)) { text(value, 16000); continue; }
    if (['clearSpeechKey', 'clearRewriteKey'].includes(key)) { if (typeof value !== 'boolean') fail(); continue; }
    if (['warmModel', 'retainAudio', 'autoPaste'].includes(key)) { if (typeof value !== 'boolean') fail(); }
    else text(value, 2000);
    next[key] = value;
  }
  if (!['local', 'cloud'].includes(next.speechProvider)) fail('Invalid speech provider');
  endpoint(next.speechEndpoint); endpoint(next.rewriteEndpoint);
  if (!/^(auto|[a-z]{2,3}(?:-[A-Za-z]{2,4})?)$/.test(next.language)) fail('Invalid speech language');
  return next;
}
module.exports = { fail, text, object, uuid, endpoint, httpsURL, normalized, workflow, importWorkflow, exportWorkflow, matchWorkflow, collection, defaults, settings, MAX_WORKFLOWS };
