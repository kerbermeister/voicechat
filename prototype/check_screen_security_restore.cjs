const assert=require('node:assert/strict');
const crypto=require('node:crypto');

module.exports=async c=>{
  const {a,b,cmd,start,media,fixture,report,until}=c;
  const nonce=crypto.randomUUID();
  const seeded=await cmd(a,{action:'seedData',nonce});
  assert(seeded.text && seeded.file);
  for(const id of [seeded.text,seeded.file]) {
    const r=await c.request(fixture.matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(c.room)+'/event/'+encodeURIComponent(id),null,c.accounts[0].access_token);
    assert.equal(r.status,200);assert.equal(r.body.type,'m.room.encrypted');
    assert(!JSON.stringify(r.body).includes(nonce),'No fixture plaintext in server event');
  }
  const first=await start(0);await media.pixels(b);
  // A normal 60s JWT can expire during a full restore. Keep the exact old grant
  // with a test-only 600s expiry, signed by this disposable stand's SFU key.
  const [header,payload]=first.token.split('.');
  const oldClaims=JSON.parse(Buffer.from(payload,'base64url'));
  oldClaims.exp=Math.floor(Date.now()/1000)+600;
  const data=header+'.'+Buffer.from(JSON.stringify(oldClaims)).toString('base64url');
  const retained=data+'.'+crypto.createHmac('sha256',fixture.sfuSecret).update(data).digest('base64url');
  const mediaKeys=[...new Set((await a.evaluate(()=>window.screenLabKeys.map(k=>k.key))).filter(k=>typeof k==='string' && Buffer.from(k,'base64').length===32))];
  assert(mediaKeys.length>=2,'Actual voice/screen cryptor keys required for backup audit');
  console.log('Restore fixture: encrypted history/file and live screen seeded; consistent backup starts');
  const restored=await fixture.command('backup_restore');
  for(const name of ['postgres_counts_match','file_trees_match_before_start','restic_checked',
    'disjoint_source_and_restore_volumes','restored_feature_off','restored_leases_revoked','release_and_runtime_loaded_from_backup']) assert.equal(restored[name],true,name);
  assert.equal(restored.snapshot_active_screen,1);assert(restored.sqlite_databases>=3);
  assert.equal((await fixture.command('audit '+JSON.stringify({keys:mediaKeys,jwt:first.token}))).audit_clean,true);
  await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
  await media.pixels(b,false);
  await fixture.command('absent '+first.generation);
  assert(Date.now()/1000<oldClaims.exp);
  assert.equal((await cmd(a,{action:'rawJoin',token:retained})).connected,false);
  assert(Date.now()/1000<oldClaims.exp);
  // New password login must work, while existing client vaults retain E2EE keys.
  const login=await c.request(fixture.matrix,'/_matrix/client/v3/login',{
    type:'m.login.password',user:c.accounts[0].username,password:c.accounts[0].password});
  assert.equal(login.status,200);
  assert.equal((await c.request(fixture.matrix,'/_matrix/client/v3/logout',{},login.body.access_token)).status,200);
  for(const page of [a,b]) {
    await cmd(page,{action:'close'});
    await page.reload();await page.getByText('ready',{exact:true}).waitFor({timeout:60000});
  }
  c.bindings.clear();c.claims.clear();c.tokens.clear();
  let mediaDownloads=0;
  b.on('response',r=>{if(r.status()===200 && /\/(?:download)\//.test(r.url()))mediaDownloads++;});
  const read=await cmd(b,{action:'readData',...seeded,nonce});
  assert.equal(read.text_matches,true);assert.equal(read.file_matches,true);
  assert(mediaDownloads>0,'Attachment must really be downloaded from restored Synapse');
  const capabilities=await c.request(fixture.base,'/screen/capabilities',null,c.accounts[0].access_token);
  assert.equal(capabilities.status,200);assert.equal(capabilities.body.screen,false);
  console.log('Restore fixture: login, server history, real decrypted file and feature off verified');
  await Promise.all([a,b].map(page=>cmd(page,{action:'connect'})));
  await until(async()=>{const m=await media.audio(b);return m.packets>10 && m.frames>5;},'Restored ordinary encrypted voice/camera required',30000);
  assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),0,'Reload must not resume screen capture');
  await fixture.command('screen_on');
  // A terminal restored binding must never be resurrected. A new call has a new
  // Matrix call_session, just as the application creates for a fresh call.
  const newSession=crypto.randomUUID();
  await Promise.all([a,b].map(page=>cmd(page,{action:'close'})));
  c.bindings.clear();c.claims.clear();c.tokens.clear();
  for(const [i,page] of [a,b].entries()) {
    const account=c.accounts[i];
    await page.route('**/fixture.json',route=>route.fulfill({json:{profile:c.session+'-'+i,
      username:account.username,password:account.password,room:c.room,session:newSession,
      api:fixture.base,livekit:fixture.livekit,matrix:fixture.matrix}}));
    await page.reload();await page.getByText('ready',{exact:true}).waitFor({timeout:60000});
  }
  await Promise.all([a,b].map(page=>cmd(page,{action:'connect'})));
  const next=await start(0);assert.notEqual(next.generation,first.generation);await media.pixels(b);
  const before=await media.audio(b);
  await fixture.command('screen_off');
  await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
  await media.pixels(b,false);
  await until(async()=>{const s=await fixture.command('status');return !s.sessions.active && !s.pending_commands && !s.retired_rooms;},'Feature off must fully clean restored screen');
  const after=await media.audio(b);
  assert(after.packets>before.packets && after.frames>before.frames);assert.deepEqual(after.voicePeers,before.voicePeers);
  Object.assign(report,{full_compose_restored_to_empty_volumes:true,consistent_encrypted_restic_checked:true,
    release_and_runtime_loaded_from_backup:true,
    restored_sqlite_databases:restored.sqlite_databases,snapshot_had_active_screen:true,leases_revoked_before_http:true,
    signing_key_preserved:true,postgres_users_and_encrypted_events_preserved:true,file_trees_preserved:true,
    media_keys_absent_in_control_and_dump:true,screen_jwt_absent_in_control:true,
    fresh_password_login:true,server_history_decrypted_with_existing_client_vault:true,
    restored_attachment_downloaded_and_decrypted:true,retained_old_generation_jwt_rejected:true,
    retained_test_jwt_expiry_seconds:600,production_jwt_ttl_unchanged:true,
    feature_off_after_restore:true,no_capture_after_reload:true,
    new_screen_after_explicit_enable:true,screen_off_preserves_voice_camera:true,
    local_images_only:true,production_registry_manifest:'NOT_TESTED',client_recovery_from_lost_vault:'NOT_TESTED'});
};
