import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../extension/status.js', import.meta.url), 'utf8');
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function popup() {
  let enabled = true;
  let failSave = false;
  let pendingSave;
  const polls = [];
  const nodes = new Map();
  const node = (id) => {
    if (!nodes.has(id)) nodes.set(id, { checked:false, disabled:true, textContent:'', title:'',
      classList:{remove(){}, add(){}, toggle(){}},
      toggleAttribute(key,value){this[key]=value;},
      addEventListener(event,handler){this[event]=handler;},
    });
    return nodes.get(id);
  };
  const snapshot = () => ({autoPause:{enabled,suppressedUntilIdle:false}});
  const context = vm.createContext({ document:{getElementById:node}, Date, console,
    window:{setInterval(){}, location:{reload(){}}},
    chrome:{storage:{local:{get:(keys,callback)=>callback({})}},runtime:{sendMessage(message,callback){
      if(message.type==='set-voiceink-auto-pause')return new Promise(resolve=>{pendingSave=()=>{
        if(!failSave)enabled=message.enabled;
        resolve({ok:!failSave,...snapshot()});
      };});
      polls.push({callback,response:snapshot()});
    }}},
  });
  vm.runInContext(source,context);
  return {node,run:(code)=>vm.runInContext(code,context),
    poll:()=>{const poll=polls.shift();assert.ok(poll);poll.callback(poll.response);},
    save:()=>pendingSave(),fail:()=>{failSave=true;},
  };
}
const ui=popup();
await settle();ui.poll();await settle();
assert.equal(ui.node('auto-pause').checked,true);
assert.equal(ui.node('auto-pause').disabled,false);
assert.equal(ui.node('auto-pause-state').textContent,'On');
console.log('PASS popup loads authoritative setting');

const oldPoll=ui.run('refresh(false)');await settle();
ui.node('auto-pause').checked=false;
const change=ui.node('auto-pause').change();
assert.equal(ui.node('auto-pause').disabled,true);
assert.equal(ui.node('auto-pause-state').textContent,'Saving...');
ui.save();await change;await settle();
assert.equal(ui.node('auto-pause').checked,false);
ui.poll();await oldPoll;await settle();
assert.equal(ui.node('auto-pause').checked,false);
ui.poll();await settle();
assert.equal(ui.node('auto-pause-state').textContent,'Off');
assert.equal(ui.node('auto-pause-detail').textContent,"YouTube won't pause or resume for VoiceInk.");
console.log('PASS saving is disabled and stale polls cannot undo acknowledged switch');

ui.fail();ui.node('auto-pause').checked=true;
const failed=ui.node('auto-pause').change();ui.save();await failed;await settle();
assert.equal(ui.node('auto-pause').checked,false);
assert.equal(ui.node('auto-pause-detail').textContent,'Failed to save setting');
ui.poll();await settle();
assert.equal(ui.node('auto-pause').checked,false);
assert.equal(ui.node('auto-pause').disabled,false);
console.log('PASS failed save restores saved value and leaves retry available');
