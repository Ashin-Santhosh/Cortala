'use strict';
const { app, BrowserWindow, ipcMain, session, safeStorage, dialog, clipboard, shell, globalShortcut } = require('electron');
const path = require('node:path');
const fs = require('node:fs/promises');
const { pathToFileURL, fileURLToPath } = require('node:url');
const { EncryptedLibrary } = require('./storage.cjs');
const { DesktopEngine } = require('./engine.cjs');
const { openKnownApp } = require('./workflows.cjs');
const validation = require('./validation.cjs');
const { validateSender, validateInvocation } = require('./security.cjs');
// Keep the existing desktop alpha library across the public-name change.
app.setPath('userData', path.join(app.getPath('appData'), app.isPackaged ? 'JustWhisper' : 'justwhisper-desktop'));
app.setName('Cortala');
let window, engine, quitting = false;
const uiDirectory = path.join(__dirname, '..', 'ui'); const uiPath = path.join(uiDirectory, 'index.html'); const uiURL = pathToFileURL(uiPath).href;
const approvedPaths = new Set();
function trusted(event) {
  validateSender(event, window, uiURL);
}
function shortcutCommand(kind) { if (!window || window.isDestroyed()) return; window.webContents.send('jw:capture-command', { command: 'toggle', kind }); }
function registerShortcuts() {
  globalShortcut.unregisterAll();
  const values = [[engine.state.prefs.shortcut, 'dictation'], [engine.state.prefs.commandShortcut, 'command']];
  for (const [accelerator, kind] of values) {
    if (!accelerator) continue;
    try { if (!globalShortcut.register(accelerator, () => shortcutCommand(kind))) engine.report(`Shortcut unavailable: ${accelerator}. Choose another shortcut in Settings.`); }
    catch { engine.report('Invalid desktop shortcut. Choose an Electron accelerator such as Control+Shift+Space.'); }
  }
}
async function choosePath(kind) {
  if (!['localModel', 'localExecutable', 'liveExecutable'].includes(kind)) throw new Error('Unsupported path selector');
  const selected = await dialog.showOpenDialog(window, { title: kind === 'localModel' ? 'Choose an existing GGML model' : 'Choose a trusted local whisper runtime', properties: ['openFile'], ...(kind === 'localModel' ? { filters: [{ name: 'GGML model', extensions: ['bin'] }] } : {}) });
  if (selected.canceled || !selected.filePaths[0]) return '';
  const value = await fs.realpath(selected.filePaths[0]); const info = await fs.stat(value); if (!info.isFile()) throw new Error('Choose a regular file');
  approvedPaths.add(`${kind}:${value}`); return value;
}
const handlers = {
  getState: () => engine.snapshot(),
  saveSettings: async prefs => {
    validation.object(prefs, [...Object.keys(validation.defaults()), 'speechKey', 'rewriteKey', 'clearSpeechKey', 'clearRewriteKey']);
    for (const key of ['localModel', 'localExecutable', 'liveExecutable']) if (prefs[key] && prefs[key] !== engine.state.prefs[key] && !approvedPaths.has(`${key}:${prefs[key]}`)) throw new Error('Use Choose file to authorize a new model or executable path');
    await engine.saveSettings(prefs); registerShortcuts(); return engine.snapshot();
  },
  choosePath,
  start: kind => engine.start(kind), captureReady: () => engine.captureReady(), stop: () => engine.stop(), cancel: () => engine.cancel(),
  copy: text => { clipboard.writeText(validation.text(text, 1000000)); },
  importAudio: async () => { if (engine.busy()) throw new Error('Finish the current action first'); const selected = await dialog.showOpenDialog(window, { properties: ['openFile'], filters: [{ name: 'WAV audio', extensions: ['wav'] }] }); if (!selected.canceled && selected.filePaths[0]) await engine.importAudio(selected.filePaths[0]); },
  exportTranscript: async id => { validation.uuid(id); const entry = engine.state.history.find(h => h.id === id); if (!entry) throw new Error('Transcript not found'); const selected = await dialog.showSaveDialog(window, { defaultPath: 'transcript.txt', filters: [{ name: 'Plain text', extensions: ['txt'] }] }); if (!selected.canceled && selected.filePath) await fs.writeFile(selected.filePath, entry.text || entry.raw, { mode: 0o600 }); },
  deleteTranscript: id => engine.deleteTranscript(id), retry: id => engine.retry(id), saveCollection: (kind, items) => engine.saveCollection(kind, items),
  importWorkflow: json => engine.importWorkflow(json), exportWorkflow: id => engine.exportWorkflow(id), runWorkflow: id => engine.runWorkflow(id),
  releaseModel: () => engine.releaseModel(), warmModel: () => engine.warmModel(), clearErrors: () => { engine.errors = []; engine.publish(); }
};
function installIPC() {
  ipcMain.handle('jw:invoke', async (event, method, args) => {
    trusted(event); validateInvocation(method, args);
    try { return await handlers[method](...args); } catch (error) { engine.report(error); throw new Error(error.message); }
  });
  ipcMain.handle('jw:pcm', (event, value) => { trusted(event); try { engine.pushPCM(value); } catch (error) { engine.report(error); throw error; } });
}
async function createWindow() {
  window = new BrowserWindow({ width: 1280, height: 850, minWidth: 1000, minHeight: 680, backgroundColor: '#101316', title: 'Cortala', icon: path.join(uiDirectory, 'icon.png'), autoHideMenuBar: true, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false, webSecurity: true, allowRunningInsecureContent: false, webviewTag: false, spellcheck: false } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.on('will-attach-webview', event => event.preventDefault());
  window.webContents.on('render-process-gone', () => { void engine.cancel(); });
  window.on('close', event => { if (engine.busy() && !quitting) { event.preventDefault(); void app.quit(); } });
  engine.on('state', state => { if (window && !window.isDestroyed()) window.webContents.send('jw:state', state); });
  await window.loadFile(uiPath);
}
app.whenReady().then(async () => {
  // A separate desktop alpha library never reads or migrates the native Mac app.
  const directory = path.join(app.getPath('userData'), 'DesktopLibrary');
  const library = new EncryptedLibrary(directory, safeStorage);
  engine = new DesktopEngine({ library, directory, runtimeDirectory: path.join(process.resourcesPath, `${process.platform}-${process.arch}`), adapters: { openURL: url => shell.openExternal(url), openApp: id => openKnownApp(id, process.platform) } });
  await engine.initialize();
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback, details) => callback(contents === window?.webContents && contents.getURL() === uiURL && permission === 'media' && engine.capture.state === 'warming' && details.mediaTypes?.every(type => type === 'audio')));
  session.defaultSession.setPermissionCheckHandler((contents, permission, _origin, details) => contents === window?.webContents && contents.getURL() === uiURL && permission === 'media' && details.isMainFrame && details.requestingUrl === uiURL && details.mediaType === 'audio' && ['warming', 'recording'].includes(engine.capture.state));
  session.defaultSession.webRequest.onBeforeRequest((details, callback) => {
    try { const url = new URL(details.url); if (url.protocol !== 'file:') return callback({ cancel: true }); const file = fileURLToPath(url); callback({ cancel: file !== uiPath && !file.startsWith(uiDirectory + path.sep) }); }
    catch { callback({ cancel: true }); }
  });
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => callback({ responseHeaders: { ...details.responseHeaders, 'Content-Security-Policy': ["default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'; media-src 'self' blob:; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-src 'none'; form-action 'none'"] } }));
  installIPC(); await createWindow(); registerShortcuts();
}).catch(error => { console.error('Cortala could not initialize:', error.message); app.quit(); });
app.on('window-all-closed', () => app.quit());
app.on('before-quit', event => {
  if (quitting || !engine) return; event.preventDefault(); quitting = true; globalShortcut.unregisterAll();
  engine.shutdown().finally(() => app.quit());
});
module.exports = { trusted };
