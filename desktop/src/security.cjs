'use strict';
const ARITY = Object.freeze({ getState: [0, 0], saveSettings: [1, 1], choosePath: [1, 1], start: [0, 1], stop: [0, 0], cancel: [0, 0], copy: [1, 1], importAudio: [0, 0], exportTranscript: [1, 1], deleteTranscript: [1, 1], retry: [1, 1], saveCollection: [2, 2], importWorkflow: [1, 1], exportWorkflow: [1, 1], runWorkflow: [1, 1], releaseModel: [0, 0], warmModel: [0, 0], clearErrors: [0, 0], captureReady: [0, 0] });
function validateSender(event, window, uiURL) {
  if (!window || window.isDestroyed() || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame || event.senderFrame?.url !== uiURL) throw new Error('Untrusted IPC sender');
}
function validateInvocation(method, args) { const arity = Object.hasOwn(ARITY, method) && ARITY[method]; if (typeof method !== 'string' || !arity || !Array.isArray(args) || args.length < arity[0] || args.length > arity[1]) throw new Error('Unsupported request'); }
module.exports = { validateSender, validateInvocation };
