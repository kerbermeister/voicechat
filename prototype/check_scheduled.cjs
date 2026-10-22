// Backend-only acceptance with signed public device keys and opaque ciphertext.
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs');
const path=require('node:path');
const secrets=JSON.parse(fs.readFileSync(path.join(__dirname,'../.prototype/secrets.json')));
const matrix='http://localhost:8008', api='http://localhost:8090';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function request(base,route,body,token,method=body?'POST':'GET') {
  const response=await fetch(base+route,{method,signal:AbortSignal.timeout(15000),
    headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},
    ...(body?{body:JSON.stringify(body)}:{})});
  return {status:response.status,data:await response.json()};
}
(async()=>{
  const username='schedule_probe_'+Date.now(),password=crypto.randomBytes(24).toString('base64url');
  const route='/_synapse/admin/v1/register';
  const {data:{nonce}}=await request(matrix,route);
  const mac=crypto.createHmac('sha1',secrets.registration).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
  assert.equal((await request(matrix,route,{nonce,username,password,admin:false,mac})).status,200);
  const login=await request(matrix,'/_matrix/client/v3/login',{type:'m.login.password',user:username,password});
  assert.equal(login.status,200);
  const owner=login.data;
  let cleanupToken=owner.access_token;
  const mx=async(route,body,token=owner.access_token,method)=>{
    const response=await request(matrix,'/_matrix/client/v3/'+route,body,token,method);
    assert.equal(response.status,200,route);
    return response.data;
  };
  async function upload(session) {
    const ed=crypto.generateKeyPairSync('ed25519'),curve=crypto.generateKeyPairSync('x25519');
    const key=publicKey=>Buffer.from(publicKey.export({format:'jwk'}).x,'base64url').toString('base64').replace(/=+$/,'');
    const device={algorithms:['m.olm.v1.curve25519-aes-sha2','m.megolm.v1.aes-sha2'],device_id:session.device_id,
      keys:{['curve25519:'+session.device_id]:key(curve.publicKey),['ed25519:'+session.device_id]:key(ed.publicKey)},user_id:session.user_id};
    const canonical=Buffer.from(JSON.stringify(device));
    const signature=crypto.sign(null,canonical,ed.privateKey);
    assert(crypto.verify(null,canonical,ed.publicKey,signature));
    device.signatures={[session.user_id]:{['ed25519:'+session.device_id]:signature.toString('base64').replace(/=+$/,'')}};
    await mx('keys/upload',{device_keys:device},session.access_token);
    return device.keys['curve25519:'+session.device_id];
  }
  try {
    const curve=await upload(owner);
    const {room_id}=await mx('createRoom',{initial_state:[{type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}}]});
    const room=encodeURIComponent(room_id);
    async function digest() {
      const keys=await mx('keys/query',{device_keys:{[owner.user_id]:[]}});
      const identities=Object.entries(keys.device_keys[owner.user_id]).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([id,data])=>
        [owner.user_id,id,data.keys['curve25519:'+id],data.keys['ed25519:'+id]]);
      return crypto.createHash('sha256').update(JSON.stringify([[owner.user_id],identities])).digest('hex');
    }
    const payload={algorithm:'m.megolm.v1.aes-sha2',ciphertext:Buffer.from('opaque scheduled fixture').toString('base64'),
      session_id:crypto.randomBytes(32).toString('base64').replace(/=+$/,''),sender_key:curve,device_id:owner.device_id};
    const queued=async(transaction,delay,extra={})=>request(api,'/scheduled',{action:'create',transaction,room_id,due:Date.now()+delay,
      audience:await digest(),payload:{...payload,...extra}},owner.access_token);
    const state=async(id,token=owner.access_token)=>(await request(api,'/scheduled?id='+id,undefined,token)).data;
    async function untilState(id,expected,token=owner.access_token) {
      for(let i=0;i<150;i++) {
        const value=await state(id,token);
        if(value.state===expected) return value;
        if(value.state==='failed' && expected!=='failed') throw new Error('Publication failed: '+value.error);
        await pause(200);
      }
      throw new Error('Scheduled state did not become '+expected);
    }
    assert.equal((await queued('too-late',49*3600*1000)).status,400);
    assert.equal((await queued('plaintext',10000,{body:'must never be stored'})).status,400);
    assert.equal((await request(api,'/scheduled',{action:'withdraw',transaction:'cancel-before-reply',room_id},owner.access_token)).status,200);
    const tombstone=await queued('cancel-before-reply',5000);
    assert.equal(tombstone.status,200); assert.equal(tombstone.data.state,'cancelled');
    const cancel=await queued('cancel',5000);
    assert.equal(cancel.status,200);
    assert.equal((await request(api,'/scheduled',{action:'cancel',id:cancel.data.id},owner.access_token)).status,200);
    assert.equal((await state(cancel.data.id)).payload,null);
    const pending=await queued('timed',4000,{'dev.voicechat.ttl_seconds':10});
    assert.equal(pending.status,200);
    const before=await mx('rooms/'+room+'/messages?dir=b&limit=20');
    assert.equal(before.chunk.filter(e=>e.type==='m.room.encrypted').length,0,'Ciphertext published before due time');
    const sent=await untilState(pending.data.id,'sent');
    assert.equal(sent.payload,null,'Published job must release its stored ciphertext');
    const event=await mx('rooms/'+room+'/event/'+encodeURIComponent(sent.event_id));
    assert(event.origin_server_ts>=sent.due,'Server event predates schedule');
    assert(event.content['org.matrix.self_destruct_after']>=event.origin_server_ts+10000);
    const replay=await queued('timed',-10000,{'dev.voicechat.ttl_seconds':10});
    assert.equal(replay.status,200);
    assert.equal(replay.data.id,pending.data.id);
    assert.equal(replay.data.event_id,sent.event_id);
    const changed=await queued('changed-keys',3000);
    assert.equal(changed.status,200);
    const authority=(await request(matrix,'/_matrix/client/v3/login',{type:'m.login.password',user:username,password})).data;
    cleanupToken=authority.access_token;
    await upload(authority);
    const rejected=await untilState(changed.data.id,'failed',authority.access_token);
    assert.equal(rejected.error,'audience_changed');
    assert(rejected.payload,'A rejected draft must remain available to its owner');
    const revoked=await queued('revoked-device',3000);
    assert.equal(revoked.status,200);
    await mx('logout',{});
    const denied=await untilState(revoked.data.id,'failed',authority.access_token);
    assert.equal(denied.error,'device_revoked');
    const after=await mx('rooms/'+room+'/messages?dir=b&limit=50',undefined,authority.access_token);
    assert.equal(after.chunk.filter(e=>e.type==='m.room.encrypted').length,1,'Duplicate, cancelled or revoked event was published');
    fs.writeFileSync(path.join(__dirname,'verified-scheduled-server-run.json'),JSON.stringify({
      run:Math.floor(Date.now()/1000),result:'PASS',scope:'real Matrix/Synapse publication of opaque fixture; not client E2EE',
      no_publication_before_due:true,limit_48_hours_enforced:true,plaintext_envelope_rejected:true,
      cancel_clears_ciphertext:true,cancellation_before_lost_create_reply_blocks_late_create:true,idempotent_replay:true,published_payload_cleared:true,
      ttl_starts_at_publication:true,changed_keys_block_publication:true,revoked_device_blocked:true,
    },null,2)+'\n');
    console.log('PASS: durable scheduled publication, time limits, cancellation, replay and revoked access');
  } finally {
    await mx('account/deactivate',{auth:{type:'m.login.password',identifier:{type:'m.id.user',user:username},password},erase:true},cleanupToken);
  }
})().catch(error=>{console.error(error.message);process.exitCode=1;});
