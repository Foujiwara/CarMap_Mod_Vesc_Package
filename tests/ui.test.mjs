import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync('ui.qml.in','utf8');
// Execute the actual QML JavaScript functions, with only Qt/transport mocked.
function extract(name) {
 const at=source.indexOf(`function ${name}(`); assert(at>=0,name);
 const start=source.indexOf('{',at);let depth=1,i=start+1,quote=null,comment=null;
 for(;depth&&i<source.length;i++) {
  const ch=source[i],next=source[i+1];
  if(comment==='line'){if(ch==='\n')comment=null;continue;}
  if(comment==='block'){if(ch==='*'&&next==='/'){comment=null;i++;}continue;}
  if(quote){if(ch==='\\'){i++;continue;}if(ch===quote)quote=null;continue;}
  if(ch==='"'||ch==="'"){quote=ch;continue;}
  if(ch==='/'&&next==='/'){comment='line';i++;continue;}
  if(ch==='/'&&next==='*'){comment='block';i++;continue;}
  if(ch==='{')depth++;if(ch==='}')depth--;
 }
 assert.equal(depth,0,name);return source.slice(at,i);
}
const sent=[];
const state={console,ArrayBuffer,DataView,Date,Math,isFinite,Error,
 VescIf:{isPortConnected:()=>true},vescCommands:{sendCustomAppData:b=>sent.push(new Uint8Array(b))},
 commandTimeout:{restart(){},stop(){}},regenDebounce:{running:false,stop(){}},
 cfgPreset:1,cfgTorqueResp:0.85,cfgSpeedCoupling:1,cfgTransWidth:0.1,cfgTransShape:1,
 cfgHighHold:0.55,cfgEngineBrake:0.15,cfgOverrunRegen:0.12,cfgRegenCurve:1,
 thrSource:0,thrInvert:0,thrMin:0.02,thrMax:0.98,thrDeadband:0.02,thrFilter:1,thrBrakeMode:2,
 mapN:21,mapData:Array(441).fill(0),txQueue:[],pendingPacket:null,mapReceived:true,cfgReceived:true,
 receivedRows:0,lastLiveTime:0,lastCmdStatus:'',benchValue:0,
 cmdSetCell:1,cmdSetMapRow:2,cmdSetConfig:3,cmdSetThr:4,cmdSave:5,cmdLoad:6,cmdReset:7,
 cmdReqMap:8,cmdReqCfg:9,cmdSetTestThr:10,rxLive:128,rxMapRow:129,rxStatus:130,rxCfgEcho:131};
vm.createContext(state);
for(const name of ['validateImport','quantizeCell','cellIdx','getCell','fxEnc','fxDec','i16Bytes','transmitPacket',
 'sendPacket','pumpTx','failTransfer','sendSetCell','sendSetMapRow','sendAllRows','sendSetConfig','sendSetThrottle',
 'sendSave','sendLoad','sendReset','requestMap','requestCfg','sendTestThrottle','handleRx','thermalPeak','shapeCurve','regenerateLocalMap']) {
 vm.runInContext(extract(name),state);
}
function ack(code=0){state.handleRx(Uint8Array.from([130,code,state.pendingPacket[0]]).buffer);}
state.sendAllRows();assert.equal(sent.length,1);assert.equal(state.txQueue.length,20);
for(let i=0;i<21;i++)ack();assert.equal(sent.length,21);assert.equal(state.pendingPacket,null);
sent.length=0;state.sendSetConfig();assert.equal(sent[0].length,17);assert.equal(sent[0][16],1);ack();
state.sendSetConfig(false);assert.equal(sent.at(-1)[16],0);ack();
state.cfgSpeedCoupling=0;state.cfgTorqueResp=1;state.regenerateLocalMap();
assert.equal(state.mapData[10*21+20],0.5);assert.equal(state.mapData[20*21+20],1);
// Save uploads all displayed parameters and cells before the flash command.
sent.length=0;state.sendSave();while(state.pendingPacket!==null)ack(state.pendingPacket[0]===5?1:0);
assert.deepEqual(sent.map(b=>b[0]),[3,4,...Array(21).fill(2),5]);assert.equal(sent[0][16],0);
assert.match(state.lastCmdStatus,/verified/);
sent.length=0;state.sendSave();ack(6);assert.equal(state.txQueue.length,0);assert.equal(sent.length,1);
assert.match(state.lastCmdStatus,/Invalid/);
// Neither side should throw when custom data belongs to another package.
for(const id of [128,129,130,131]) for(let n=0;n<2;n++) {
 const b=new Uint8Array(n);if(n)b[0]=id;assert.doesNotThrow(()=>state.handleRx(b.buffer));
}
const outOfBounds=new Uint8Array(44);outOfBounds[0]=129;outOfBounds[1]=255;
state.handleRx(outOfBounds.buffer);assert.equal(state.mapData.length,441);
assert.throws(()=>state.validateImport({map:Array(441).fill(NaN)}));
assert.throws(()=>state.validateImport({map:Array(440).fill(0)}));
assert.throws(()=>state.validateImport({map:Array(441).fill(0),cfg:{preset:1}}));
assert.doesNotThrow(()=>state.validateImport({map:Array(441).fill(-0.5)}));
state.pendingPacket=null;state.txQueue=[];state.requestMap();ack();assert.equal(state.mapReceived,false);
assert.match(state.lastCmdStatus,/Incomplete/);
console.log('QML JavaScript regression tests passed');
