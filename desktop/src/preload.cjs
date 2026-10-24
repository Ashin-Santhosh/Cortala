'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const methods = ['getState', 'saveSettings', 'choosePath', 'start', 'stop', 'cancel', 'copy', 'importAudio', 'exportTranscript', 'deleteTranscript', 'retry', 'saveCollection', 'importWorkflow', 'exportWorkflow', 'runWorkflow', 'releaseModel', 'warmModel', 'clearErrors', 'captureReady'];
const bridge = Object.fromEntries(methods.map(method => [method, (...args) => ipcRenderer.invoke('jw:invoke', method, args)]));
bridge.pushPCM = samples => {
  if (!(samples instanceof Float32Array) || samples.length < 1 || samples.length > 32000) return Promise.reject(new Error('Invalid audio frame'));
  return ipcRenderer.invoke('jw:pcm', samples);
};
function subscription(channel, callback) {
  if (typeof callback !== 'function') throw new Error('Callback required');
  const listener = (_event, value) => callback(value); ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}
bridge.subscribe = callback => subscription('jw:state', callback);
bridge.subscribeCommands = callback => subscription('jw:capture-command', callback);
contextBridge.exposeInMainWorld('justWhisper', Object.freeze(bridge));
