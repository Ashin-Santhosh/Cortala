'use strict';
const path = require('node:path');
const fs = require('node:fs/promises');
const { workflow, httpsURL } = require('./validation.cjs');
const { spawn } = require('node:child_process');
const { cleanEnvironment } = require('./capture.cjs');
async function runWorkflow(value, adapters, signal) {
  const checked = workflow(value);
  for (const action of checked.actions) {
    if (signal?.aborted) throw new Error('Workflow cancelled; completed actions remain applied');
    if (action.kind === 'openURL') await adapters.openURL(httpsURL(action.value));
    if (action.kind === 'webSearch') { const url = new URL('https://www.google.com/search'); url.searchParams.set('q', action.value); await adapters.openURL(url.href); }
    if (action.kind === 'openApp') await adapters.openApp(action.value);
    if (action.kind === 'delay') await (adapters.delay || delay)(Number(action.value) * 1000, signal);
  }
}
function delay(ms, signal) { return new Promise((resolve, reject) => { const finish = () => { signal?.removeEventListener('abort', cancel); resolve(); }; const timer = setTimeout(finish, ms); const cancel = () => { clearTimeout(timer); signal?.removeEventListener('abort', cancel); reject(new Error('Workflow cancelled')); }; signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel(); }); }
function appCandidates(id, platform, environment = process.env) {
  const aliases = { 'org.mozilla.firefox': 'firefox', 'com.google.Chrome': 'chrome', 'com.microsoft.edgemac': 'edge', 'com.openai.chat': 'chatgpt' }; id = aliases[id] || id.toLowerCase();
  if (platform === 'win32') {
    const roots = [environment.ProgramFiles, environment['ProgramFiles(x86)'], environment.LOCALAPPDATA].filter(Boolean);
    const tails = { firefox: ['Mozilla Firefox/firefox.exe'], chrome: ['Google/Chrome/Application/chrome.exe'], edge: ['Microsoft/Edge/Application/msedge.exe'] }[id] || [];
    return roots.flatMap(root => tails.map(tail => path.join(root, tail)));
  }
  if (platform === 'linux') return ({ firefox: ['/usr/bin/firefox', '/snap/bin/firefox'], chrome: ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'], edge: ['/usr/bin/microsoft-edge'], chatgpt: [] })[id] || [];
  return [];
}
async function openKnownApp(id, platform, environment) {
  for (const candidate of appCandidates(id, platform, environment)) {
    try { const stat = await fs.stat(candidate); if (!stat.isFile()) continue; await new Promise((resolve, reject) => { const child = spawn(candidate, [], { shell: false, detached: true, windowsHide: false, stdio: 'ignore', env: cleanEnvironment() }); child.once('error', reject); child.once('spawn', () => { child.unref(); resolve(); }); }); return; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  throw new Error(`Application “${id}” is not supported or installed on this platform. Use an HTTPS website action instead.`);
}
module.exports = { runWorkflow, appCandidates, openKnownApp, delay };
