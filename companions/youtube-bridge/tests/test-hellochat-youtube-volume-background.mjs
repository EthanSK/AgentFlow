// Execute the production worker with isolated Chrome/message fixtures; run with Node,
// or TEST_EXTENSION_DIR to qualify the packaged worker without live media. — GPT-6.1 Sol
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const read = file => fs.readFileSync(new URL(`${process.env.TEST_EXTENSION_DIR || '../extension'}/${file}`, import.meta.url), 'utf8');
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
function setup(stored = {}, initialUrl = 'https://video.example/watch') {
  const runtimeMessages = event(), nativeMessages = event(), commands = [], injections = [], nativeReplies = [];
  let url = initialUrl;
  let liveDocument = 'embed-document';
  let playing = true;
  let playBlocked = false;
  let queryDelay = null;
  let clockOffset = 0;
  const clock = class extends Date { static now() { return Date.now() + clockOffset; } };
  const chrome = {
    runtime: { id: 'extension', getURL: p => `chrome-extension://extension/${p}`,
      onMessage: runtimeMessages, onInstalled: event(), onStartup: event(),
      connectNative: () => ({ onMessage: nativeMessages, onDisconnect: event(), postMessage: message => nativeReplies.push(message) }) },
    storage: { local: { get: async keys => Object.fromEntries((Array.isArray(keys) ? keys : [keys]).map(k => [k, structuredClone(stored[k])])),
      set: async value => Object.assign(stored, structuredClone(value)), remove: async key => { delete stored[key]; } } },
    windows: { getLastFocused: async () => ({ id: 1 }), onRemoved: event() },
    alarms: { create() {}, clear: async () => true, onAlarm: event() },
    scripting: { executeScript: async request => { injections.push(request); return []; } },
    tabs: {
      onRemoved: event(), onActivated: event(), onReplaced: event(), onUpdated: event(),
      query: async () => {
        if (queryDelay) await queryDelay();
        return []; // The volume fixture supplies candidates after normal worker startup.
      },
      get: async () => ({ id: 7, url, windowId: 1, active: true, audible: playing }),
      sendMessage(id, message, options, callback) {
        if (typeof options === 'function') { callback = options; options = undefined; }
        if (message.type === 'state-request') { callback?.({ ok: true }); return; }
        commands.push({ id, message, options });
        if (['explicit-rewind-five', 'explicit-rewind-ten'].includes(message.command ?? message.type)) {
          callback?.({ ok: true, sought: true, reason: 'rewound' }); return;
        }

        if (message.type === 'generic-video-command') {
          if (options?.documentId !== liveDocument) {
            chrome.runtime.lastError = { message: 'Document is gone' }; callback?.(); delete chrome.runtime.lastError; return;
          }
          const pause = ['pause-youtube', 'explicit-pause-video'].includes(message.command);
          const play = ['resume-youtube', 'explicit-play-video'].includes(message.command);
          const paused = pause && playing;
          const resumed = play && !playing && !playBlocked;
          if (paused) playing = false;
          if (resumed) playing = true;
          callback?.({ ok: true, paused, resumed, reason: paused || resumed ? 'changed' :
            play ? (playBlocked ? 'play-blocked' : 'already-playing') : 'not-playing',
            sought: message.command === 'seek-youtube', speedHeld: message.command !== 'end-youtube-speed-hold' });
        } else {
          const paused = message.type === 'explicit-pause-video' && playing;
          const resumed = message.type === 'explicit-play-video' && !playing;
          if (paused) playing = false;
          if (resumed) playing = true;
          callback?.({ ok: true, paused, resumed: resumed || message.type === 'resume-youtube',
            reason: paused || resumed ? 'changed' : message.type === 'explicit-pause-video' ? 'not-playing' : 'already-playing' });
        }
      },
    },
  };
  let context;
  context = vm.createContext({ chrome, console: { debug() {}, warn() {} }, Date: clock, Map, Set, Promise, URL,
    // Accelerate only the browser deadline, preserving retry/backoff semantics in other fixtures.
    setTimeout: (fn, ms) => setTimeout(fn, ms === 2000 ? 5 : ms), clearTimeout,
    importScripts: (...files) => files.forEach(file => vm.runInContext(read(file), context)),
  });
  vm.runInContext(read('background.js'), context);
  const run = expression => vm.runInContext(expression, context);
  const sender = { id: 'extension', tab: { id: 7, title: 'Synthetic video', url }, frameId: 14, documentId: liveDocument, url: 'https://embed.example/player' };
  const report = (message, senderOverride = {}) => runtimeMessages.listeners[0](message, { ...sender, ...senderOverride }, () => {});
  report({ type: 'generic-video-state', instanceId: 'embed-instance', mediaId: 'exact-video', playing: true, area: 200000 });
  return { stored, run, commands, injections, report, chrome, nativeReplies,
    native: message => nativeMessages.listeners[0](message),
    blockPlay: () => { playBlocked = true; },
    setPlaying: value => { playing = value; },
    delayQuery: fn => { queryDelay = fn; },
    advanceClock: milliseconds => { clockOffset += milliseconds; },
    start: () => run("enqueueDictationOp('fixture-start', () => pauseYouTubeForDictation('fixture'))"),
    stop: () => run("enqueueDictationOp('fixture-stop', () => resumeYouTubeForDictation('fixture'))"),
    finish: () => run("enqueueDictationOp('fixture-finish', () => finishDictationPreservingPlayback('fixture'))"),
    navigate: () => { url = 'https://www.youtube.com/watch?v=different'; liveDocument = 'replacement-document';
      chrome.tabs.onUpdated.listeners.forEach(fn => fn(7, { url }, { url })); },
  };
}


const idle=f=>f.run('dictationOpChain');
const results=f=>f.nativeReplies.filter(m=>m.type==='hellochat-video-result');
const uuid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const request=(f,n,value,issuedAt=Date.now())=>f.native({type:'hellochat-video-command',requestId:uuid(n),videoAction:'setVolume',volumePercent:value,issuedAt});
const tab=(id,extra={})=>({id,url:`https://www.youtube.com/watch?v=test${id}`,windowId:1,active:false,audible:false,playing:false,paused:true,pip:false,doc:`document-${id}`, ...extra});
function fixture(tabs=[tab(7,{active:true})], options={}) {
 const f=setup(options.stored || {});const map=new Map(tabs.map(t=>[t.id,t]));let discovered=0,mutations=0;
 f.run('tabPlayState.clear()');
 for(const t of tabs)if(t.playing || t.pip)f.run(`tabPlayState.set(${t.id}, ${JSON.stringify({playing:t.playing,isPiP:t.pip,lastPlayedAt:Date.now(),url:t.url})})`);
 f.chrome.tabs.query=async()=>{if(options.queryDelay)options.queryDelay(f);return tabs;};
 f.chrome.tabs.get=async id=>{if(!map.has(id))throw new Error('missing tab');return map.get(id);};
 f.chrome.scripting.executeScript=async req=>{
  f.injections.push(req);assert.equal(req.files,undefined,'discovery never injects a receiver');
  const t=map.get(req.target.tabId);return [{frameId:0,documentId:t.doc,result:t.url}];
 };
 f.chrome.tabs.sendMessage=(id,m,opts,cb)=>{
  if(typeof opts==='function'){cb=opts;opts=undefined;}
  if(m.type==='state-request'){cb?.({ok:true});return;}
  if(!['youtube-volume-discover','set-youtube-volume'].includes(m.type)){cb?.({ok:true,paused:false,resumed:false});return;}
  f.commands.push({id,message:m,options:opts});const t=map.get(id);
  if(m.type==='set-youtube-volume' && options.beforeMutation)options.beforeMutation(t,f);
  if(opts?.documentId!==t.doc || (options.missingReceiver && m.type==='set-youtube-volume')){
   f.chrome.runtime.lastError={message:'Document receiver unavailable'};cb();delete f.chrome.runtime.lastError;return;
  }
  if(m.type==='youtube-volume-discover'){
   discovered++;if(options.afterDiscovery)options.afterDiscovery(t,f);
   cb(options.discoveryFailure || (t.noVideo?{eligible:false,reason:'no-video'}:{eligible:true,playerToken:uuid(id),playing:t.playing,paused:t.paused,isPiP:t.pip}));return;
  }
  mutations++;
  assert.equal(m.playerToken,uuid(id));
  cb(options.mutationFailure || {changed:true,confirmed:true,volumePercent:m.volumePercent,playing:t.playing,paused:t.paused,muted:true,reason:'volume-set'});
 };
 return Object.assign(f,{map,discovered:()=>discovered,mutations:()=>mutations});
}
const writes=f=>f.commands.filter(c=>c.message.type==='set-youtube-volume');
const f=fixture();
f.native({type:'hellochat-video-status-request',requestId:uuid(0),issuedAt:Date.now()});
assert.deepEqual(Array.from(f.nativeReplies.find(m=>m.requestId===uuid(0)).capabilities),['youtubeAbsoluteVolume']);
request(f,1,30);request(f,1,30);await idle(f);
assert.equal(writes(f).length,1);assert.equal(results(f).length,1);assert.equal(results(f)[0].confirmed,true);
assert.equal(results(f)[0].volumePercent,30);assert.equal(results(f)[0].paused,true);assert.equal(results(f)[0].muted,true);
assert.equal(f.run('dictationPlaybackRelinquished'),false);
for(const [i,invalid] of [-1,101,1.5,true,'30',null,undefined].entries()) {request(f,10+i,invalid);await idle(f);assert.equal(results(f).at(-1).changed,false);}
assert.equal(writes(f).length,1);
request(f,50,20,Date.now()-3000);await idle(f);assert.equal(writes(f).length,1);
const generic=fixture([tab(7,{url:'https://video.example/watch',active:true})]);request(generic,60,20);await idle(generic);
assert.equal(writes(generic).length,0);assert.equal(results(generic).at(-1).reason,'no-youtube-target');
for(const options of [{mutationFailure:{confirmed:false,changed:false,reason:'volume-unconfirmed'}},{missingReceiver:true}]){
 const failed=fixture(undefined,options);request(failed,70,20);await idle(failed);
 assert.equal(results(failed).at(-1).confirmed,false);assert.equal(writes(failed).length,1);
 assert.equal(failed.injections.filter(v=>v.files).length,0);
}
const stale=fixture(undefined,{queryDelay:f=>f.advanceClock(3000)});request(stale,80,20);await idle(stale);assert.equal(writes(stale).length,0);
// The active paused page must not consume a command for audible background playback (review finding 1).
const background=fixture([tab(7,{active:true}),tab(8,{playing:true,paused:false,audible:true})]);
request(background,90,20);await idle(background);assert.equal(writes(background)[0].id,8);assert.equal(writes(background).length,1);
// A retained paused player outranks an unrelated active paused page when nothing is playing.
const retained=fixture([tab(7,{active:true}),tab(8)]);retained.run('helloChatPausedTarget={tabId:8}');
request(retained,91,20);await idle(retained);assert.equal(writes(retained)[0].id,8);
const pip=fixture([tab(7,{active:true,playing:true,paused:false,audible:true}),tab(8,{pip:true})]);
request(pip,92,20);await idle(pip);assert.equal(writes(pip)[0].id,8);
const ambiguous=fixture([tab(7,{playing:true,paused:false,audible:true}),tab(8,{playing:true,paused:false,audible:true})]);
request(ambiguous,93,20);await idle(ambiguous);assert.equal(writes(ambiguous).length,0);assert.equal(results(ambiguous).at(-1).reason,'ambiguous-youtube-target');
const none=fixture([tab(7,{noVideo:true})]);request(none,94,20);await idle(none);assert.equal(writes(none).length,0);
// Same-URL document replacement and different navigation both lose the frozen Chrome binding (finding 2).
for(const changeURL of [false,true]){
 const replaced=fixture(undefined,{beforeMutation:t=>{t.doc='replacement-document';if(changeURL)t.url+='-replacement';}});
 request(replaced,95,20);await idle(replaced);assert.equal(replaced.mutations(),0);assert.equal(writes(replaced).length,1);
 assert.equal(results(replaced).at(-1).confirmed,false);assert.equal(replaced.injections.filter(v=>v.files).length,0);
}
// Unknown discovery refuses before effect, and an uncertain effect never searches another player.
const unknown=fixture(undefined,{discoveryFailure:{eligible:true,playing:true,paused:false,isPiP:false}});
request(unknown,96,20);await idle(unknown);assert.equal(writes(unknown).length,0);
const uncertain=fixture([tab(7,{active:true,playing:true,paused:false}),tab(8)],{mutationFailure:{reason:'uncertain'}});
request(uncertain,97,20);await idle(uncertain);assert.equal(writes(uncertain).length,1);assert.equal(results(uncertain).at(-1).confirmed,false);
// Setting a level leaves the existing recording lease and explicit ownership untouched.
const owned=fixture();owned.run('dictationDepth=2;dictationPlaybackRelinquished=false');request(owned,98,20);await idle(owned);
assert.equal(owned.run('dictationDepth'),2);assert.equal(owned.run('dictationPlaybackRelinquished'),false);

// Current automatic pause ownership survives old playback recency (review finding 3).
const bindAutomatic=f=>f.run("dictationDepth=1;dictationPausedTabId=8;dictationPlaybackRelinquished=false;dictationAutoPauseSuppressed=false;dictationStartedAt=Date.now();dictationLastActivityAt=Date.now();tabPlayState.set(8,{playing:false,lastPlayedAt:Date.now()-120000,isPiP:false,url:'https://www.youtube.com/watch?v=test8'});");
const automatic=fixture([tab(7,{active:true}),tab(8)]);bindAutomatic(automatic);
request(automatic,110,10);await idle(automatic);assert.equal(writes(automatic)[0].id,8);
assert.equal(automatic.run('dictationPausedTabId'),8);assert.equal(automatic.run('dictationDepth'),1);
for(const change of ['dictationPlaybackRelinquished=true','dictationAutoPauseSuppressed=true','dictationStartedAt=Date.now()-MAX_DICTATION_MS-1','dictationDepth=0']){
 const retired=fixture([tab(7,{active:true}),tab(8)]);bindAutomatic(retired);retired.run(change);
 request(retired,111,10);await idle(retired);assert.ok(writes(retired).every(c=>c.id!==8),change);
}
const disabledOwner=fixture([tab(7,{active:true}),tab(8)],{stored:{voiceInkAutoPauseEnabled:false}});bindAutomatic(disabledOwner);
request(disabledOwner,115,10);await idle(disabledOwner);assert.ok(writes(disabledOwner).every(c=>c.id!==8));
const endedOwner=fixture([tab(7,{active:true}),tab(8,{noVideo:true})]);bindAutomatic(endedOwner);
request(endedOwner,112,10);await idle(endedOwner);assert.equal(writes(endedOwner).length,0,'no substitute for an ended retained owner');
const closedOwner=fixture([tab(7,{active:true})]);bindAutomatic(closedOwner);
request(closedOwner,113,10);await idle(closedOwner);assert.equal(writes(closedOwner).length,0,'removed target refuses before effect');
const lostDuringDiscovery=fixture([tab(7,{active:true}),tab(8)],{afterDiscovery:(t,f)=>{if(t.id===8)f.run('dictationPlaybackRelinquished=true');}});bindAutomatic(lostDuringDiscovery);
request(lostDuringDiscovery,114,10);await idle(lostDuringDiscovery);assert.equal(writes(lostDuringDiscovery).length,0,'later manual takeover invalidates the same lease');
const restored=fixture([tab(7,{active:true}),tab(8)],{stored:{dictationPausedTabId:8,dictationState:{depth:1,startedAt:Date.now(),lastActivityAt:Date.now(),token:7,playbackRelinquished:false,autoPauseSuppressed:false}}});
request(restored,115,10);await idle(restored);assert.equal(writes(restored)[0].id,8);assert.equal(restored.run('dictationDepth'),1);

console.log('H Chat absolute YouTube volume production worker/document/selection cases: PASS');
