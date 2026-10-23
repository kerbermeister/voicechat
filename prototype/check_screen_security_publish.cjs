const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const path=require('node:path');
const {randomUUID}=require('node:crypto');

module.exports=async c=>{
  const {a,b,cmd,start,api,media,until,report}=c;
  await until(async()=>{const r=await media.audio(b);return r.packets>0 && r.frames>0;},'Base voice/camera required');
  const first=await start(0);await media.pixels(b);const before=await media.audio(b);
  function metadata(generation) {
    return JSON.parse(execFileSync('python3',['-c',`import sys,json
sys.path.insert(0,'prototype')
from token_server import media_api
r=media_api('ListParticipants',{'room':sys.stdin.read()})
t=[t for p in r.get('participants',[]) for t in p.get('tracks',[])]
print(json.dumps({'tracks':len(t),'encryption':[v.get('encryption') for v in t],'sources':[v.get('source') for v in t]}))`],
      {cwd:path.join(__dirname,'..'),input:generation,encoding:'utf8',stdio:['pipe','pipe','pipe']}));
  }
  const denied=[];
  for(const [label,page,channel,source] of [
    ['owner camera in screen room',a,'screen','camera'],
    ['screen source in voice room',a,'voice','screen'],
    ['viewer publishes screen',b,'screen','screen'],
  ]) {
    const r=await cmd(page,{action:'signal',channel,source});
    assert.equal(r.published,false,label+' must be denied by actual SFU signaling');
    const state=(await api(a,'state')).body;
    assert.equal(state.generation,first.generation);
    const m=metadata(first.generation);assert.equal(m.tracks,1);
    assert.deepEqual(m.encryption,['GCM']);assert.deepEqual(m.sources,['SCREEN_SHARE']);
    await media.pixels(b);denied.push(label);
  }
  // Isolate server enforcement from an honest viewer's immediate local unbind.
  // B remains in the actual voice/video call, but leaves only the screen binding.
  const binding=c.bindings.get(b);
  const left=await c.request(c.fixture.base,'/screen/unbind',{protocol_version:1,
    binding_id:binding.binding_id,lease_id:binding.lease_id,request_id:randomUUID()},binding.auth.slice(7));
  assert.equal(left.status,200);
  let ownerOnly;
  await until(async()=>{
    ownerOnly=(await api(a,'state')).body;
    return ownerOnly.state==='active' && ownerOnly.roster.length===1 && ownerOnly.generation!==first.generation;
  },'Owner must rotate screen after viewer voluntarily leaves it');
  await until(()=>metadata(ownerOnly.generation).tracks===1,'Owner-only screen must actually publish before attack');
  const revoked=[];
  for(const kind of ['duplicate','plaintext']) {
    const response=await api(a,'state');assert.equal(response.status,200,'Live owner state required');
    const state=response.body;
    const pattern=c.fixture.base+'/screen/**',block=route=>route.abort();
    if(kind==='plaintext') await a.route(pattern,block);
    try {
      const r=await cmd(a,{action:'attack',kind,token:c.tokens.get(a).token});
      assert.equal(r.published,true,'Negative track must actually be accepted before metadata enforcement: '+kind);
      await until(async()=>{
        const response=await api(a,'state');assert.equal(response.status,200,'Binding must remain authorized');
        return response.body.generation!==state.generation;
      },'Production guard must revoke '+kind,10000);
    } finally {
      if(kind==='plaintext') await a.unroute(pattern,block);
    }
    c.absent(state.generation);
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    await media.pixels(b,false);
    revoked.push(kind);
    if(kind==='duplicate') {
      const next=await start(0);
      await until(()=>metadata(next.generation).tracks===1,'New screen publication required');
    }
  }
  const after=await media.audio(b);
  assert(after.packets>before.packets && after.frames>before.frames);
  assert.deepEqual(after.voicePeers,before.voicePeers);
  report.direct_sfu_signal_denied=denied;report.real_metadata_guard_revoked=revoked;
  report.guard_deleted_rooms_and_stopped_capture=true;report.voice_camera_preserved=true;
  report.metadata_guard_test_roster_size=1;report.voice_video_participants=2;
};
