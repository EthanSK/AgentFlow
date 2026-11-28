// Test the production absolute-volume receiver and its one-use exact-player binding without real media. — GPT-6.1 Sol
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL(`${process.env.TEST_EXTENSION_DIR || '../extension'}/content-script.js`, import.meta.url),
  'utf8',
);

class FakeVideo extends EventTarget {
  constructor() {
    super();
    this.paused = false;
    this.ended = false;
    this.playbackRate = 1;
    this.currentTime = 30;
    this.duration = 120;
    this.volume = 0.5;
    this.muted = false;
  }
}

let tokenSerial = 0;
let video = new FakeVideo();
let runtimeListener;
const context = vm.createContext({
  console,
  crypto: { randomUUID: () => `00000000-0000-4000-8000-${String(++tokenSerial).padStart(12, '0')}` },
  Date,
  URL,
  Promise,
  EventTarget,
  HTMLVideoElement: FakeVideo,
  MutationObserver: class {
    observe() {}
    disconnect() {}
  },
  document: {
    title: 'Test video',
    documentElement: {},
    pictureInPictureElement: null,
    querySelector: () => video,
  },
  location: { href: 'https://www.youtube.com/watch?v=test' },
  setTimeout,
  clearTimeout,
  window: {
    setInterval: () => 1,
    clearInterval: () => {},
  },
  chrome: {
    runtime: {
      lastError: undefined,
      sendMessage: (_message, callback) => callback?.(),
      onMessage: {
        addListener: (listener) => { runtimeListener = listener; },
        removeListener: () => {},
      },
    },
  },
});

vm.runInContext(source, context, { filename: 'content-script.js' });
assert.equal(typeof runtimeListener, 'function');

const adjustVolume = (volumeDelta) => {
  let response;
  runtimeListener(
    { type: 'adjust-youtube-volume', volumeDelta },
    null,
    (value) => { response = value; },
  );
  return response;
};


const send=message=>{let response;runtimeListener(message,null,value=>{response=value});return response;};
let serial=0;
const discover=()=>{
 const requestId=`00000000-0000-4000-8000-${String(++serial).padStart(12,'0')}`,expiresAt=Date.now()+2000;
 return {...send({type:'youtube-volume-discover',requestId,expiresAt}),requestId,expiresAt};
};
const apply=(binding,percent,extra={})=>send({type:'set-youtube-volume',playerToken:binding.playerToken,requestId:binding.requestId,
 volumePercent:percent,expiresAt:binding.expiresAt,...extra});
const absolute=percent=>apply(discover(),percent);
for(const paused of [false,true])for(const muted of [false,true])for(const percent of [0,10,30,100]) {
 video.paused=paused;video.muted=muted;video.volume=.57;
 const result=absolute(percent);assert.equal(result.confirmed,true);assert.equal(video.volume,percent/100);
 assert.equal(video.paused,paused);assert.equal(video.muted,muted);assert.equal(result.playing,!paused);
 assert.equal(result.paused,paused);assert.equal(result.muted,muted);assert.equal(absolute(percent).changed,false);
}
for(const value of [-1,101,1.5,true,'30',null,undefined,NaN,Infinity]) {
 video.volume=.57;assert.equal(absolute(value).confirmed,false);assert.equal(video.volume,.57);
}
for(const extra of [{expiresAt:Date.now()-1},{expiresAt:undefined},{playerToken:'wrong'},{requestId:'wrong'}]) {
 video.volume=.57;assert.equal(apply(discover(),30,extra).confirmed,false);assert.equal(video.volume,.57);
}
const binding=discover();assert.equal(apply(binding,30).confirmed,true);video.volume=.57;
assert.equal(apply(binding,30).confirmed,false,'one-use player token');assert.equal(video.volume,.57);
for(const mutate of [()=>{video=new FakeVideo();},()=>{video.currentSrc='new-source';},()=>{context.location.href+='-other';},()=>{video.ended=true;}]) {
 const old=video,b=discover();mutate();const current=video.volume;
 assert.equal(apply(b,30).confirmed,false);assert.equal(video.volume,current);old.ended=false;video=old;
 context.location.href='https://www.youtube.com/watch?v=test';video.currentSrc=undefined;
}
const pip=new FakeVideo();pip.paused=true;pip.muted=true;pip.volume=.8;
context.document.pictureInPictureElement=pip;video.volume=.57;
assert.equal(absolute(30).confirmed,true);assert.equal(pip.volume,.3);assert.equal(video.volume,.57);
assert.equal(pip.paused,true);assert.equal(pip.muted,true);
const previous=discover();context.document.pictureInPictureElement=null;
assert.equal(apply(previous,30).confirmed,false,'a changed active player invalidates discovery');
context.document.pictureInPictureElement=pip;
Object.defineProperty(pip,'volume',{get(){return .8},set(_v){},configurable:true});assert.equal(absolute(30).confirmed,false);
Object.defineProperty(pip,'volume',{get(){return .3},set(_v){},configurable:true});assert.equal(absolute(30).confirmed,true);
assert.equal(send({type:'youtube-volume-discover',requestId:'bad',expiresAt:Date.now()+1000}).eligible,false);
console.log('H Chat absolute YouTube volume production receiver/player-binding cases: PASS');
