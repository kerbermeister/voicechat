const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');

module.exports=async c=>{
  const {a,b,cmd,start,media,until,report,identities}=c;
  await until(async()=>{const r=await media.audio(b);return r.packets>0 && r.frames>0;},'Real base voice/camera required');
  const owner=identities[0].user+'/'+identities[0].device;
  const first=await start(0);await media.pixels(b);
  const old=await cmd(b,{action:'envelope',generation:first.generation});
  const middle=await start(1);await media.pixels(a,true,[201,97,49]);
  await cmd(a,{action:'gate',enabled:true});
  const current=await start(0);
  await until(async()=>{const r=await cmd(b,{action:'inspect'});return r.generation===current.generation && r.frames===0;},'Fresh generation must initially have no decoded frames');
  await until(async()=>(await cmd(a,{action:'inspect'})).dropped>0,'Normal current key must actually be withheld');
  await until(()=>c.tokens.get(b)?.generation===current.generation,'Viewer must request the new room token');
  let screenProvider;
  await until(async()=>{
    const r=await b.evaluate(data=>window.screenLab(data),{action:'provider',channel:'screen'});
    if(r.error || !r.connected || r.generation!==current.generation)return false;
    screenProvider=r.id;return true;
  },'New viewer key provider must become ready');
  const voiceProvider=(await cmd(b,{action:'provider',channel:'voice'})).id;
  async function inputs(page,id) {return page.evaluate(({id,owner})=>window.screenLabKeys.filter(k=>k.id===id && k.owner===owner),{id,owner});}
  const voiceKey=(await inputs(b,voiceProvider)).at(-1)?.key;
  assert(voiceKey,'Positive base voice key must be installed');
  assert.equal((await inputs(b,screenProvider)).length,0,'No current screen key may be installed before test');
  const fresh=await cmd(a,{action:'currentEnvelope'});
  fresh.key=(await inputs(a,fresh.provider_id)).at(-1)?.key;delete fresh.provider_id;
  assert(fresh.key && Buffer.from(fresh.key,'base64').length===32,'Actual sender raw key must be observed');
  assert(fresh.key!==old.key && fresh.screen_generation!==old.screen_generation,'New generation needs a different media key');
  const before=await media.audio(b),cases=[];
  async function send(label,content,{type='dev.voicechat.screen_key.v1',plaintext=false}={}) {
    content={...content,lab_case:label};
    if(plaintext) {
      const {status}=await c.request('http://localhost:8008','/_matrix/client/v3/sendToDevice/'+type+'/'+randomUUID(),
        {messages:{[identities[1].user]:{[identities[1].device]:content}}},c.accounts[0].access_token,'PUT');
      assert.equal(status,200);
    } else {
      await cmd(a,{action:'send',user:identities[1].user,device:identities[1].device,type,content});
    }
    await until(async()=>(await cmd(b,{action:'inspect'})).received.includes(label),'Actual Matrix delivery required: '+label);
    // Event delivery alone does not await the async production key handler.
    for(let i=0;i<3;i++) {
      await new Promise(r=>setTimeout(r,100));
      assert.equal((await inputs(b,screenProvider)).length,0,'Rejected envelope must never reach screen cryptor: '+label);
      assert((await inputs(b,voiceProvider)).at(-1)?.key===voiceKey,'Rejected envelope changed voice key: '+label);
    }
    assert.equal((await cmd(b,{action:'inspect'})).frames,0,'No fallback to plaintext/old key');
    cases.push(label);
  }
  assert(old.expires_at>Date.now(),'Exact old envelope must still be unexpired');
  await send('exact old envelope in fresh Olm message',old);
  await send('old generation with fresh expiry',{...old,expires_at:Date.now()+20000});
  for(const [name,change] of [
    ['other call',{call_session:'other-call'}],['other room',{room_id:'!other:voicechat.local'}],
    ['other binding',{binding_id:randomUUID()}],['old revision',{revision:fresh.revision-1}],
    ['old roster',{roster_version:fresh.roster_version-1}],['forged sender',{sender_identity:identities[1].user+'/'+identities[1].device}],
    ['forged device',{sender_device:identities[1].device}],['expired',{expires_at:Date.now()-1}],
    ['overlong expiry',{expires_at:Date.now()+120000}],['malformed key',{key:'!'.repeat(44)}],
    ['boolean protocol',{protocol_version:true}],
  ]) await send(name,{...fresh,expires_at:Date.now()+20000,...change});
  // Never intentionally disclose an actual media key to Matrix in plaintext.
  await send('plaintext screen key',{...fresh,key:Buffer.alloc(32,5).toString('base64'),expires_at:Date.now()+20000},{plaintext:true});
  await send('screen envelope in voice channel',{...fresh,expires_at:Date.now()+20000},{type:'dev.voicechat.probe.media_key'});
  const positive={...fresh,expires_at:Date.now()+20000,lab_case:'valid current encrypted key'};
  await cmd(a,{action:'send',user:identities[1].user,device:identities[1].device,type:'dev.voicechat.screen_key.v1',content:positive});
  await until(async()=>(await cmd(b,{action:'inspect'})).frames>5,'Valid current envelope must restore actual decoding');
  assert((await inputs(b,screenProvider)).at(-1)?.key===fresh.key,'Positive control must install the actual current key');
  assert((await inputs(b,voiceProvider)).at(-1)?.key===voiceKey,'Screen key must not replace voice key');
  await media.pixels(b);const after=await media.audio(b);
  assert(after.packets>before.packets && after.frames>before.frames);assert.deepEqual(after.voicePeers,before.voicePeers);
  await cmd(a,{action:'gate',enabled:false});
  const secrets=[old.key,fresh.key];
  assert(c.wire.every(body=>secrets.every(key=>!body.includes(key))),'Actual media keys must not cross control or unencrypted Matrix HTTP bodies');
  const control=await c.fixture.command('audit '+JSON.stringify({text:['screen_sessions'],base64:[]}));
  assert.equal(control.audit_clean,false,'Audit must detect a known nonsecret SQLite schema string');
  const audit=await c.fixture.command('audit '+JSON.stringify({
    text:[...secrets,first.token,middle.token,current.token,...[...c.bindings.values()].map(v=>v.auth.slice(7))],base64:secrets}));
  assert(audit.audit_clean,'Private SQLite must not store media keys or bearer tokens');
  report.rejected_cases=cases;report.real_encrypted_matrix_delivery=true;
  report.cryptor_key_unchanged_for_each_negative=true;report.missing_key_decoded_frames=0;
  report.valid_current_key_installed_and_visible_pixels=true;report.voice_key_and_connections_unchanged=true;
  report.actual_keys_absent_from_control_and_unencrypted_matrix_bodies=true;
  report.sqlite_media_keys_and_bearer_tokens_absent=true;report.audit_negative_control_detected=true;
};
