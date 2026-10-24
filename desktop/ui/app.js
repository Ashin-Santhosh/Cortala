'use strict';
(() => {
  const bridge = window.justWhisper;
  const $ = (id) => document.getElementById(id);
  const pages = [['home','⌂','Home'],['meetings','◉','Meetings'],['workflows','☷','Workflows'],['vocabulary','Aa','Vocabulary'],['snippets','▧','Snippets'],['modes','✧','Modes'],['configuration','⚙','Configuration'],['models','▣','Models'],['errors','!','Errors'],['help','?','Help & tutorial']];
  let state = null, page = 'home', session = null, captureBusy = false, generation = 0;
  let workflowDraft = null, collectionDraft = null, fallbackTimer = null, fallbackShown = '', search = '', lastErrorID;
  const uid = () => crypto.randomUUID();
  function h(tag, props = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (key === 'class') node.className = value;
      else if (key === 'text') node.textContent = value;
      else if (key.startsWith('on')) node.addEventListener(key.slice(2).toLowerCase(), value);
      else if (key === 'disabled' || key === 'checked' || key === 'hidden') node[key] = Boolean(value);
      else if (key === 'value') node.value = value ?? '';
      else node.setAttribute(key, value);
    }
    for (const child of children.flat(Infinity)) {
      if (child == null) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }
  const button = (text, action, style = '', disabled = false) => h('button', {text, class:style, disabled, onclick:() => perform(action)});
  const row = (...children) => h('div', {class:'row'}, children);
  const hint = (text) => h('p', {class:'hint', text});
  const empty = (title, text) => h('div', {class:'empty'}, h('div',{class:'empty-icon',text:'≋'}), h('h3',{text:title}),h('p',{text}));
  function panel(title, subtitle, ...children) {
    return h('section',{class:'panel'}, title ? h('div',{class:'panel-header'},h('div',{},h('h2',{text:title}),subtitle ? h('p',{text:subtitle}) : null)) : null, children);
  }
  function header(eyebrow, title, description) { return h('div',{class:'page-header'},h('span',{class:'eyebrow',text:eyebrow}),h('h1',{text:title}),h('p',{text:description})); }
  function input(label, value, placeholder = '', type = 'text') {
    const control = h('input',{type,value,placeholder});
    return {control,node:h('label',{class:'field'},h('span',{text:label}),control)};
  }
  function area(label, value, placeholder = '') {
    const control = h('textarea',{placeholder}); control.value = value || '';
    return {control,node:h('label',{class:'field'},h('span',{text:label}),control)};
  }
  function select(label, value, options) {
    const control = h('select',{},options.map(([key,name]) => h('option',{value:key,text:name}))); control.value = value ?? '';
    return {control,node:h('label',{class:'field'},h('span',{text:label}),control)};
  }
  function check(label, value) {
    const control = h('input',{type:'checkbox',checked:value});
    return {control,node:h('label',{class:'check'},control,h('span',{text:label}))};
  }
  function notify(message, error = false) { $('notice').textContent = message; $('notice').className = error ? 'error' : ''; $('notice').hidden = !message; }
  async function perform(action) {
    try { await action(); } catch (error) { notify(error?.message || String(error), true); }
  }
  function duration(value = 0) { const s = Math.max(0, Math.floor(Number(value) || 0)); return `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`; }
  function date(value) { const d = new Date(value); return Number.isNaN(d.getTime()) ? '' : d.toLocaleString(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}); }
  function busy() { return captureBusy || Boolean(session) || ['warming','recording','processing'].includes(state?.capture?.state); }
  async function refresh() { accept(await bridge.getState()); }
  function accept(snapshot) {
    if (!snapshot || typeof snapshot !== 'object') return;
    state = snapshot;
    const newestError = state.errors?.at(-1);
    if (lastErrorID !== undefined && newestError && newestError.id !== lastErrorID) notify(newestError.message, true);
    lastErrorID = newestError?.id || '';
    if (session && !captureBusy && state.capture?.state === 'idle') void perform(cancelCapture);
    $('platform').textContent = ({win32:'Windows',linux:'Linux',darwin:'macOS preview'})[state.platform] || 'Desktop';
    $('version').textContent = `JustWhisper ${state.version || ''}`;
    $('connection-status').textContent = state.model?.phase === 'ready' ? 'Local model ready' : 'Your workspace';
    updateCapture(); showFallback();
    if (!document.activeElement?.matches('input,textarea,select') && !workflowDraft && !collectionDraft) render();
  }
  function navigate(next) { page = pages.some(p => p[0] === next) ? next : 'home'; workflowDraft = null; collectionDraft = null; search = ''; render(); }
  function render() {
    if (!state) return;
    $('navigation').replaceChildren(...pages.map(([id,icon,name]) => h('button',{class:page === id ? 'active' : '',title:name,'aria-label':name,'aria-current':page === id ? 'page' : 'false',onclick:() => navigate(id)},h('span',{class:'nav-icon',text:icon}),h('span',{class:'nav-text',text:name}))));
    $('page-name').textContent = pages.find(p => p[0] === page)[2];
    const content = ({home:home,meetings:meetings,workflows:workflows,vocabulary:() => collection('vocabulary'),snippets:() => collection('snippets'),modes:() => collection('modes'),configuration:configuration,models:models,errors:errors,help:help})[page]();
    $('page').replaceChildren(...(Array.isArray(content) ? content : [content]));
  }
  function captureButtons(kind) {
    const recording = Boolean(session) && !captureBusy;
    return row(button(recording ? '■  Stop recording' : state.capture?.state === 'processing' ? 'Transcribing…' : captureBusy || state.capture?.state === 'warming' ? 'Preparing…' : '●  Start recording', () => recording ? stopCapture() : startCapture(kind),'primary', captureBusy || (!recording && busy())), busy() ? button('Cancel',cancelCapture,'subtle') : null);
  }
  function home() {
    const history = state.history || [];
    const words = history.reduce((sum,item) => sum + (item.text || '').split(/\s+/u).filter(Boolean).length,0);
    const mode = select('Mode',state.prefs?.selectedModeID || '',[['','Plain dictation'],...(state.modes || []).map(item => [item.id,item.name])]);
    mode.control.disabled = busy();
    mode.control.addEventListener('change',() => perform(async () => {await bridge.saveSettings({selectedModeID:mode.control.value}); await refresh();}));
    const hero = h('section',{class:'panel hero'},h('div',{class:'hero-top'},h('div',{},h('span',{class:'eyebrow',text:'LET YOUR THOUGHTS FLOW'}),h('h2',{text:'Turn a thought into words.'}),h('p',{text:'Capture your voice, keep your momentum. Start here to transcribe, review, and copy into the app you’re working in.'})),h('span',{class:'hero-wave',text:'≋'})),h('div',{class:'hero-mode'},mode.node),captureButtons('dictation'),hint(`${state.prefs?.shortcut || 'Configure a global shortcut'} to start and stop · ${state.prefs?.speechProvider === 'cloud' ? 'Cloud recognition sends the full audio file after Stop.' : 'Local recognition uses your configured model and helper.'}`));
    const stats = h('div',{class:'grid'},...[[history.length,'RECORDINGS','Saved in your workspace'],[words.toLocaleString(),'WORDS CAPTURED','From your saved transcripts'],[duration(history.reduce((n,item) => n + (item.duration || 0),0)),'TIME RECORDED','Every thought adds up']].map(([value,label,caption]) => h('div',{class:'stat'},h('span',{class:'eyebrow',text:label}),h('strong',{text:value}),h('small',{text:caption}))));
    const latest = state.lastResult?.text ? panel('Latest transcript','Ready for your next step.',h('div',{class:'transcript transcript-preview',text:state.lastResult.text}),row(button('Copy transcript',() => copy(state.lastResult.text),'primary'))) : null;
    const searchControl = h('input',{class:'search',type:'search',placeholder:'Search transcripts…',value:search,'aria-label':'Search transcripts',oninput:(event) => {search = event.target.value; renderHistory(list);}});
    const list = h('div',{class:'list'}); renderHistory(list);
    const historyPanel = panel(null,null,h('div',{class:'panel-header'},h('div',{},h('h2',{text:'Your recordings'}),h('p',{text:'A little history of your big ideas.'})),row(searchControl,button('Import audio',() => bridge.importAudio(),'',busy()))),list);
    return [header('YOUR WORKSPACE','Welcome back.','A quieter way to get your thoughts down.'),hero,stats,latest,historyPanel].filter(Boolean);
  }
  function renderHistory(list) {
    const items = (state.history || []).filter(item => `${item.title} ${item.text} ${item.raw}`.toLowerCase().includes(search.toLowerCase()));
    list.replaceChildren(...(items.length ? items.map(item => {
      const body = h('div',{class:'transcript detail',text:item.text || item.raw || 'Awaiting transcription'});
      return h('article',{class:'list-item'},row(h('h3',{text:item.title || 'Untitled recording'}),h('span',{class:'spacer'}),h('span',{class:'hint',text:`${date(item.date)} · ${duration(item.duration)}`})),body,row(item.isMeeting ? h('span',{class:'tag',text:'Meeting'}) : null,button('Copy',() => copy(item.text || item.raw || '')),button('Export',() => bridge.exportTranscript(item.id)),button('Retry',() => bridge.retry(item.id),'',busy() || !item.audioAvailable),button('Delete',async () => {await bridge.deleteTranscript(item.id); await refresh();},'danger',busy())));
    }) : [empty(search ? 'No matching recordings' : 'Your next idea starts here',search ? 'Try another word or phrase.' : 'Start a recording or import an audio file. Your transcripts will appear here.')]));
  }
  function meetings() {
    return [header('MEETINGS','Be present. Keep the details.','Record your microphone, then review and copy the transcript from Home.'),panel('Microphone meeting capture','Make sure everyone knows you are recording.',captureButtons('meeting'),h('div',{class:'warning',text:'This desktop version records your microphone. Other participants are captured only if their audio reaches that microphone.'}),hint(state.prefs?.speechProvider === 'cloud' ? 'The full meeting recording is sent to your configured speech provider after Stop. No live cloud captions are shown.' : 'Live provisional text appears only when the local model and streaming helper are ready. Final transcription follows Stop.')),panel('Available on this platform',null,...[['System audio',state.capabilities?.systemAudio],['Speaker diarization',state.capabilities?.diarization]].map(([name,supported]) => row(h('strong',{text:name}),h('span',{class:'spacer'}),h('span',{class:supported ? 'tag' : 'hint unavailable',text:supported ? 'Available through configured backend' : 'Unavailable in this build'}))),hint('Live translation and Apple speech services are unavailable in this desktop version.'))];
  }
  function collection(kind) {
    const specs = {vocabulary:{title:'Vocabulary',intro:'Teach your transcripts the words you use.',fields:[['phrase','Recognized phrase'],['replacement','Replace with']]},snippets:{title:'Snippets',intro:'Small phrases. More room for what matters.',fields:[['trigger','Trigger phrase'],['text','Expanded text']]},modes:{title:'Modes',intro:'Shape the way your voice becomes text.',fields:[['name','Mode name'],['instruction','Formatting instruction']]}};
    const spec = specs[kind], items = state[kind] || [];
    const list = panel(spec.title,`${items.length} saved ${kind}`,row(button(`New ${kind === 'vocabulary' ? 'word' : kind.slice(0,-1)}`,() => {collectionDraft = {id:uid()}; render();},'primary')),h('div',{class:'list'},...(items.length ? items.map(item => h('article',{class:'list-item'},row(h('h3',{text:item[spec.fields[0][0]] || 'Untitled'}),h('span',{class:'spacer'}),button('Edit',() => {collectionDraft = {...item}; render();}),button('Delete',async () => {await bridge.saveCollection(kind,items.filter(v => v.id !== item.id)); await refresh();},'danger')),h('p',{text:item[spec.fields[1][0]] || (kind === 'modes' ? 'Plain dictation · no formatting instruction' : '')}))) : [empty(`Make ${spec.title.toLowerCase()} your own`,'Add your first entry to get started.')])));
    let editor = null;
    if (collectionDraft) {
      const fields = spec.fields.map(([key,label]) => ({key,...(key === 'instruction' || key === 'text' ? area(label,collectionDraft[key]) : input(label,collectionDraft[key]))}));
      editor = panel('Edit entry',null,...fields.map(f => f.node),row(button('Save entry',async () => {const next = {...collectionDraft}; for (const field of fields) next[field.key] = field.control.value; const values = items.filter(v => v.id !== next.id); values.push(next); await bridge.saveCollection(kind,values); collectionDraft = null; await refresh(); render();},'primary'),button('Cancel',() => {collectionDraft = null; render();},'subtle')));
    }
    return [header('MAKE IT YOURS',spec.title,spec.intro),kind === 'modes' ? hint('Formatting requires a configured rewrite model. Choose the mode for your next recording on Home.') : null,list,editor].filter(Boolean);
  }
  function workflows() {
    const items = state.workflows || [];
    const list = panel('Your workflows','Only explicit command recordings can match an enabled phrase.',row(button('Record command',() => session?.kind === 'command' ? stopCapture() : startCapture('command'),'primary',captureBusy || (busy() && session?.kind !== 'command')),button('New workflow',() => {workflowDraft = {id:uid(),name:'',phrase:'',enabled:false,actions:[]}; render();})),hint(`${state.prefs?.commandShortcut || 'Set a command shortcut in Configuration'} · unique enabled matches run immediately.`),h('div',{class:'list'},...(items.length ? items.map(item => h('article',{class:'list-item'},row(h('h3',{text:item.name}),h('span',{class:'tag',text:item.enabled ? 'Enabled' : 'Disabled'})),h('p',{text:`“${item.phrase}” · ${item.actions.length} ordered actions`}),row(button('Run',() => bridge.runWorkflow(item.id),'',busy()),button('Edit',() => {workflowDraft = structuredClone(item); render();}),button('Copy JSON',async () => {await copy(await bridge.exportWorkflow(item.id));}),button('Delete',async () => {await bridge.saveCollection('workflows',items.filter(v => v.id !== item.id)); await refresh();},'danger')))) : [empty('A phrase for your routine','Build a sequence of supported actions, then run it with your voice.')])));
    const json = area('Shared workflow JSON','','Paste one workflow here');
    const share = panel('Bring a workflow along','Imports receive new identities and stay disabled until you review and enable them.',json.node,button('Import as disabled',async () => {await bridge.importWorkflow(json.control.value); json.control.value = ''; await refresh(); notify('Workflow imported disabled. Review every action before enabling.');}));
    const editor = workflowDraft ? workflowEditor(items) : null;
    return [header('A LITTLE LESS REPETITION','Voice workflows','Your chosen phrase. Your sequence of actions. Always deliberate.'),list,editor,share].filter(Boolean);
  }
  function workflowEditor(items) {
    const draft = workflowDraft;
    const name = input('Workflow name',draft.name,'Morning research'); name.control.oninput = () => draft.name = name.control.value;
    const phrase = input('Exact command phrase',draft.phrase,'Begin research'); phrase.control.oninput = () => draft.phrase = phrase.control.value;
    const enabled = check('Enabled for voice command matching',draft.enabled); enabled.control.onchange = () => draft.enabled = enabled.control.checked;
    const actions = h('div',{},draft.actions.map((action,index) => {
      const kind = select('Action',action.kind,[['openApp','Open app'],['openURL','Open website'],['webSearch','Search web'],['delay','Wait']]);
      kind.control.setAttribute('aria-label',`Action ${index+1} type`); kind.control.onchange = () => {action.kind = kind.control.value; action.value = ''; render();};
      const value = h('input',{value:action.value,placeholder:({openApp:'firefox, chrome, edge, chatgpt',openURL:'https://example.com',webSearch:'Search terms',delay:'Seconds (0–30)'})[action.kind],'aria-label':`Action ${index+1} value`,oninput:(event) => action.value = event.target.value});
      return h('div',{class:'action-row'},kind.control,value,row(button('↑',() => { [draft.actions[index-1],draft.actions[index]] = [draft.actions[index],draft.actions[index-1]]; render();},'',index === 0),button('↓',() => {[draft.actions[index+1],draft.actions[index]] = [draft.actions[index],draft.actions[index+1]]; render();},'',index === draft.actions.length-1),button('×',() => {draft.actions.splice(index,1); render();},'danger')));
    }));
    return panel('Workflow editor','Steps run in order. A failure or cancellation stops remaining actions.',h('div',{class:'form-grid'},name.node,phrase.node),enabled.node,actions,row(button('Add action',() => {draft.actions.push({id:uid(),kind:'openURL',value:''}); render();},'',draft.actions.length >= 20),h('span',{class:'spacer'}),button('Cancel',() => {workflowDraft = null; render();},'subtle'),button('Save workflow',async () => {await bridge.saveCollection('workflows',[...items.filter(v => v.id !== draft.id),draft]); workflowDraft = null; await refresh(); render();},'primary')),hint('Open app accepts supported logical app names, not executable paths. HTTPS websites cannot contain credentials, query strings, or fragments. No shell scripts, window placement, numbered Spaces, or automatic voice-mode activation are available.'));
  }
  function configuration() {
    const prefs = state.prefs || {}, fields = {};
    const add = (key,label,placeholder = '',type='text') => {fields[key] = input(label,prefs[key],placeholder,type); return fields[key].node;};
    const provider = select('Speech recognition',prefs.speechProvider,[['local','Local · on this computer'],['cloud','Cloud · configured endpoint']]); fields.speechProvider = provider;
    const warm = check('Keep the local model warm',prefs.warmModel), retain = check('Retain recorded audio for playback and retry',prefs.retainAudio), paste = check('Paste into the original app when supported',prefs.autoPaste);
    paste.control.disabled = !state.capabilities?.autoPaste;
    const speechKey = input('New speech API key','','Enter a key to replace the saved credential','password'); speechKey.control.autocomplete = 'off';
    const rewriteKey = input('New formatting API key','','Enter a key to replace the saved credential','password'); rewriteKey.control.autocomplete = 'off';
    const clearSpeech = check('Remove saved speech credential',false), clearRewrite = check('Remove saved formatting credential',false);
    const save = async () => {
      const changes = Object.fromEntries(Object.entries(fields).map(([key,field]) => [key,field.control.value]));
      Object.assign(changes,{warmModel:warm.control.checked,retainAudio:retain.control.checked,autoPaste:paste.control.checked});
      if (speechKey.control.value) changes.speechKey = speechKey.control.value;
      if (rewriteKey.control.value) changes.rewriteKey = rewriteKey.control.value;
      if (clearSpeech.control.checked) changes.clearSpeechKey = true;
      if (clearRewrite.control.checked) changes.clearRewriteKey = true;
      speechKey.control.value = ''; rewriteKey.control.value = '';
      await bridge.saveSettings(changes); await refresh(); notify('Settings saved.');
    };
    return [header('YOUR SETUP','Configuration','Choose where your audio goes and how JustWhisper fits your day.'),panel('Speech provider','Local stays on your computer. Cloud sends the complete recording after Stop.',h('div',{class:'form-grid'},provider.node,add('language','Language','auto'),add('speechEndpoint','Speech endpoint','https://…'),add('speechModel','Speech model','whisper-1')),speechKey.node,clearSpeech.node,hint('Saved credentials never return to this page. Credentials are stored by the main process and bound to the endpoint origin.')),panel('Formatting provider','Optional instructions can add a formatting step after speech recognition.',h('div',{class:'form-grid'},add('rewriteEndpoint','Formatting endpoint','http://localhost:11434/v1/chat/completions'),add('rewriteModel','Formatting model','Leave empty for plain dictation')),rewriteKey.node,clearRewrite.node),panel('Recording & behavior',null,h('div',{class:'form-grid'},add('shortcut','Recording shortcut','CommandOrControl+Alt+Space'),add('commandShortcut','Workflow command shortcut','CommandOrControl+Shift+Space')),warm.node,retain.node,paste.node,hint(state.capabilities?.autoPaste ? 'Auto-paste uses the platform adapter when a safe target is available; otherwise copy the transcript.' : 'Safe automatic paste is unavailable on this platform. A copy panel appears after recording.'),h('div',{class:'warning',text:'Microphone permission is requested only when you start recording. Backgrounding or losing the microphone cancels an active recording.'}),button('Save settings',save,'primary',busy()))];
  }
  function models() {
    const prefs = state.prefs || {}, controls = {};
    const modelFields = [['localModel','Local speech model','Choose your local model file.'],['localExecutable','Final transcription helper','Select a compatible local transcription executable.'],['liveExecutable','Live recognition helper','Select the streaming helper for provisional text.']].map(([key,label,description]) => {
      const field = input(label,prefs[key]); controls[key] = field.control;
      return h('div',{},field.node,row(button('Choose file…',async () => {const path = await bridge.choosePath(key); if (path) field.control.value = path;})),hint(description));
    });
    return [header('ON YOUR COMPUTER','Models','Bring your own local model. Stay in control of your audio.'),panel('Local model status',null,row(h('span',{class:'tag',text:state.model?.phase || 'Not configured'}),h('span',{class:'detail',text:state.model?.detail || 'Configure a model and helpers below.'})),row(button('Warm model',() => bridge.warmModel(),'primary',busy()),button('Release model',() => bridge.releaseModel(),'',busy())),hint('Live text is provisional. It is available only when the streaming helper and model are ready. Cloud recognition is never used as a silent fallback.')),panel('Local model files','Paths stay local and are selected deliberately.',...modelFields,button('Save local setup',async () => {await bridge.saveSettings(Object.fromEntries(Object.entries(controls).map(([key,control]) => [key,control.value]))); await refresh(); notify('Local model setup saved.');},'primary',busy())),panel('Downloads & compatibility',null,hint('This build does not download models automatically. Use a model compatible with your configured transcription helper. Model and helper licenses remain their publishers’ responsibility.'))];
  }
  function errors() {
    const items = state.errors || [];
    return [header('WHEN SOMETHING NEEDS ATTENTION','Activity & errors','Actionable details from recording, providers, and local models.'),panel(null,null,h('div',{class:'panel-header'},h('h2',{text:'Recent errors'}),button('Clear errors',async () => {await bridge.clearErrors(); await refresh();},'',!items.length)),h('div',{class:'list'},...(items.length ? [...items].reverse().map(item => h('article',{class:'list-item'},h('span',{class:'hint',text:date(item.date)}),h('p',{text:item.message}))) : [empty('All clear','Provider and recording errors will appear here when something needs your attention.')]))),state.storage ? panel('Workspace storage',null,h('p',{text:state.storage.detail || (state.storage.persistent ? 'Your workspace is saved locally.' : 'Persistent storage is unavailable.')})) : null].filter(Boolean);
  }
  function help() {
    const steps = [['Choose your recognition route','In Configuration, choose local recognition or configure a cloud endpoint. For local recognition, select compatible model and helper files in Models.'],['Start with a simple thought','Press Start recording on Home or use your configured global shortcut. Grant microphone permission when asked. Watch the level meter to check your input.'],['Stop, review, and copy','Stop recording to finish transcription. Local live text is provisional; cloud recognition starts after Stop. Review the result in Home, then copy it deliberately.'],['Build a voice routine','Add a workflow with an exact phrase and ordered actions. Enable it after reviewing. Use Record command or its separate shortcut; ordinary dictation never runs workflows.']];
    return [header('A SMALL TOUR','Make room for your voice.','A few useful things to know before your first recording.'),panel('Your first recording',null,h('div',{class:'steps'},steps.map(([title,text]) => h('div',{class:'step'},h('div',{},h('h3',{text:title}),h('p',{text}))))),button('Go to Home',() => navigate('home'),'primary')),panel('Privacy, in plain language',null,h('p',{text:'Microphone capture starts only after an explicit recording action. Local recognition stays on your computer; cloud recognition sends the complete audio file to the configured provider after Stop. No always-listening wake word is used.'}),h('p',{text:'API keys stay in the main process after you save them. Workflow JSON can include private search terms or URL paths; review it before sharing. Imported workflows are disabled until you enable them.'})),panel('Platform limits',null,h('p',{text:'This Windows/Linux renderer does not provide Apple speech services, Apple translation, arbitrary Space selection, or window placement. Meetings use microphone capture first. System audio, speaker identification, and automatic paste are available only when the platform capabilities explicitly report support.'}),h('p',{text:'Backgrounding the app cancels active microphone capture. If a device disconnects, recording stops safely and reports the interruption. Use Home to review saved recordings.'}))];
  }
  async function copy(text) { await bridge.copy(String(text || '')); notify('Copied to clipboard.'); }
  function updateCapture() {
    const capture = state?.capture || {}, active = captureBusy || Boolean(session) || ['warming','recording','processing'].includes(capture.state);
    $('capture-dock').hidden = !active;
    $('capture-label').textContent = capture.state === 'processing' || (captureBusy && session?.worklet) ? 'Finishing transcription…' : captureBusy ? 'Preparing microphone…' : capture.state === 'warming' ? 'Preparing local model…' : capture.kind === 'command' ? 'Listening for a command…' : 'Listening to you…';
    $('capture-time').textContent = duration(capture.duration || (session ? (Date.now()-session.started)/1000 : 0));
    $('capture-partial').textContent = capture.partial || (capture.state === 'processing' ? 'Your transcript will appear on Home.' : '');
    $('capture-level').style.width = `${Math.min(100,Math.max(0,Number(capture.level || session?.level || 0)*100))}%`;
    $('dock-stop').disabled = captureBusy || !session;
    if (!active && session) void cancelCapture();
  }
  function showFallback() {
    const result = state?.lastResult;
    if (!result?.copyFallback || !result.text || result.text === fallbackShown) return;
    fallbackShown = result.text; $('fallback-text').textContent = result.text; $('copy-fallback').hidden = false;
    resetFallbackTimer();
  }
  function resetFallbackTimer() { clearTimeout(fallbackTimer); fallbackTimer = setTimeout(() => {$('copy-fallback').hidden = true;},3000); }
  async function disposeCapture(current) {
    if (!current) return;
    current.failed = true;
    for (const track of current.stream?.getTracks() || []) { track.onended = null; track.stop(); }
    current.worklet?.disconnect(); current.source?.disconnect(); current.gain?.disconnect();
    if (current.context && current.context.state !== 'closed') await current.context.close();
  }
  async function startCapture(kind = 'dictation') {
    if (captureBusy || session || busy()) return;
    const token = ++generation; captureBusy = true; updateCapture(); render();
    const current = {started:Date.now(),context:null,stream:null,worklet:null,pending:Promise.resolve(),pendingChunks:0,failed:false,kind};
    session = current;
    try {
      await bridge.start(kind);
      if (token !== generation) throw new Error('Recording cancelled.');
      current.stream = await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,sampleRate:16000,echoCancellation:true,noiseSuppression:true},video:false});
      if (token !== generation) throw new Error('Recording cancelled.');
      current.context = new AudioContext({sampleRate:16000});
      if (current.context.sampleRate !== 16000) throw new Error('Your audio device cannot provide a 16 kHz recording context. Choose another input device.');
      await current.context.audioWorklet.addModule('pcm-worklet.js');
      if (token !== generation) throw new Error('Recording cancelled.');
      current.source = current.context.createMediaStreamSource(current.stream);
      current.worklet = new AudioWorkletNode(current.context,'mono-pcm',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1]});
      current.gain = current.context.createGain(); current.gain.gain.value = 0;
      current.worklet.port.onmessage = ({data}) => {
        if (data.type === 'pcm' && !current.failed) {
          if (++current.pendingChunks > 4) {current.failed = true; notify('Audio delivery fell behind. Recording was cancelled safely.',true); void perform(cancelCapture); return;}
          current.pending = current.pending.then(() => bridge.pushPCM(data.samples)).finally(() => {current.pendingChunks--;});
          current.pending.catch(error => {if (!current.failed) {current.failed = true; notify(error.message,true); void cancelCapture();}});
        } else if (data.type === 'level') {current.level = data.level; updateCapture();}
        else if (data.type === 'flushed') current.flushed?.();
      };
      for (const track of current.stream.getTracks()) track.onended = () => {notify('The microphone disconnected. Recording was cancelled.',true); void cancelCapture();};
      current.source.connect(current.worklet); current.worklet.connect(current.gain); current.gain.connect(current.context.destination);
      await current.context.resume();
      await bridge.captureReady();
      if (token !== generation) throw new Error('Recording cancelled.');
      current.started = Date.now(); captureBusy = false; updateCapture(); render();
    } catch (error) {
      await disposeCapture(current);
      if (session === current) session = null;
      if (token === generation) {captureBusy = false; await bridge.cancel().catch(() => {}); notify(error.name === 'NotAllowedError' ? 'Microphone permission was denied. Allow microphone access for JustWhisper, then try again.' : error.message,true); await refresh(); render();}
    }
  }
  async function stopCapture() {
    if (captureBusy || !session) return;
    const current = session, token = generation; captureBusy = true; updateCapture();
    try {
      await new Promise((resolve,reject) => {
        const timer = setTimeout(() => reject(new Error('The microphone did not finish safely. Recording was cancelled.')),2000);
        current.flushed = () => {clearTimeout(timer); resolve();}; current.worklet.port.postMessage('flush');
      });
      await current.pending;
      await disposeCapture(current);
      if (token !== generation) return;
      session = null;
      await bridge.stop();
    } catch (error) {await disposeCapture(current); if (token === generation) {session = null; await bridge.cancel().catch(() => {}); notify(error.message,true);}}
    finally {captureBusy = false; await refresh(); render();}
  }
  async function cancelCapture() {
    ++generation; const current = session; session = null; captureBusy = true;
    try {await disposeCapture(current); await bridge.cancel();} finally {captureBusy = false; if (bridge) await refresh(); updateCapture(); render();}
  }
  $('dock-stop').addEventListener('click',() => perform(stopCapture));
  $('dock-cancel').addEventListener('click',() => perform(cancelCapture));
  $('fallback-copy').addEventListener('click',() => perform(() => copy($('fallback-text').textContent)));
  $('fallback-dismiss').addEventListener('click',() => {$('copy-fallback').hidden = true; clearTimeout(fallbackTimer);});
  $('copy-fallback').addEventListener('mouseenter',() => clearTimeout(fallbackTimer));
  $('copy-fallback').addEventListener('mouseleave',resetFallbackTimer);
  $('copy-fallback').addEventListener('focusin',() => clearTimeout(fallbackTimer));
  $('copy-fallback').addEventListener('focusout',resetFallbackTimer);
  document.addEventListener('visibilitychange',() => {if (document.hidden && (session || captureBusy)) void perform(cancelCapture);});
  window.addEventListener('blur',() => {if (session && !captureBusy) void perform(cancelCapture);});
  window.addEventListener('beforeunload',() => {void disposeCapture(session); void bridge?.cancel().catch(() => {});});
  window.addEventListener('hashchange',() => navigate(location.hash.slice(1)));
  if (!bridge) {notify('The desktop bridge is unavailable. Open this page through the JustWhisper desktop app.',true); return;}
  bridge.subscribe(accept);
  bridge.subscribeCommands((value) => {
    const command = typeof value === 'string' ? value : value.command;
    const kind = value.kind || 'dictation';
    void perform(async () => {
      if (command === 'cancel') return cancelCapture();
      if (command === 'stop') return stopCapture();
      if (command === 'toggle' && session) {if (session.kind === kind) return stopCapture(); return;}
      if (command === 'toggle' || command === 'start') return startCapture(kind);
    });
  });
  navigate(location.hash.slice(1) || 'home');
  void perform(refresh);
})();
