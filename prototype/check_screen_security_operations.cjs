const assert=require('node:assert/strict');
const crypto=require('node:crypto');

module.exports=async c=>{
  const {a,b,cmd,fixture,media,until,report}=c;
  const initial=await fixture.command('status');assert.equal(initial.schema,1);
  async function ordinaryCallWorks() {
    await b.bringToFront();
    await until(async()=>{const m=await media.audio(b);return m.packets>10 && m.frames>5;},'Ordinary E2EE voice/camera required',30000);
  }
  async function seed() {
    const nonce=crypto.randomUUID(),ids=await cmd(a,{action:'seedData',nonce});
    assert(ids.text && ids.file);return {...ids,nonce};
  }
  async function read(data) {
    let downloads=0;const observe=r=>{if(r.status()===200 && /\/download\//.test(r.url()))downloads++;};
    b.on('response',observe);
    try {
      const r=await cmd(b,{action:'readData',...data});
      assert(r.text_matches && r.file_matches,'Server history and encrypted file must survive');
      return downloads;
    } finally {b.off('response',observe);}
  }
  async function newCall(screen) {
    console.log('Operations: closing previous clients before reload');
    await Promise.all([a,b].map(page=>cmd(page,{action:'close'})));
    c.bindings.clear();c.claims.clear();c.tokens.clear();
    const session=crypto.randomUUID();
    for(const [i,page] of [a,b].entries()) {
      const account=c.accounts[i];
      await page.route('**/fixture.json',route=>route.fulfill({json:{profile:c.session+'-'+i,
        username:account.username,password:account.password,room:c.room,session,
        api:fixture.base,livekit:fixture.livekit,matrix:fixture.matrix}}));
      await page.reload();await page.getByText('ready',{exact:true}).waitFor({timeout:60000});
    }
    console.log('Operations: reloaded preserved client vaults; connecting voice/camera');
    await Promise.all([a,b].map(page=>cmd(page,{action:'connect',screen})));
    await ordinaryCallWorks();
  }
  async function capabilities(expected) {
    const r=await fetch(fixture.base+'/screen/capabilities',{headers:{Authorization:'Bearer '+c.accounts[0].access_token}});
    assert.equal(r.status,expected===null ? 404 : 200);
    if(expected!==null)assert.equal((await r.json()).screen,expected);
  }
  await ordinaryCallWorks();await capabilities(null);
  const before=await seed();
  const upgraded=await fixture.command('upgrade');
  assert.equal(upgraded.schema,2);
  for(const key of ['same_volume_names','postgres_counts_preserved','signing_key_preserved','legacy_tombstone_preserved','backup_checked_before_switch'])assert.equal(upgraded[key],true);
  await capabilities(false);await newCall(true);
  assert((await read(before))>0,'Original file must actually download after upgrade');
  assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),0);
  console.log('Operations: same volumes upgraded v1 to v2; old data and ordinary call work');
  const after=await seed();
  await fixture.command('screen_on');
  await Promise.all([a,b].map(page=>cmd(page,{action:'rejoin'})));
  await ordinaryCallWorks();
  const active=await c.start(0);await media.pixels(b);
  const refused=await fixture.command('rollback');
  assert.equal(refused.rollback_refused_until_screen_stopped,true);
  assert.equal(refused.sessions.active,1);await media.pixels(b);
  const voice=await media.audio(b);
  await fixture.command('screen_off');
  await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
  await media.pixels(b,false);await fixture.command('absent '+active.generation);
  await until(async()=>{const s=await fixture.command('status');return !s.sessions.active && !s.pending_commands && !s.retired_rooms;},'Screen must quiesce before rollback');
  const still=await media.audio(b);assert(still.packets>voice.packets && still.frames>voice.frames);assert.deepEqual(still.voicePeers,voice.voicePeers);
  const rolled=await fixture.command('rollback');
  console.log('Operations: baseline image restored on the same volumes, additive schema preserved');
  assert.equal(rolled.running_image,fixture.baseline);assert.equal(rolled.schema,2);
  assert(rolled.same_volume_names && rolled.postgres_counts_preserved && rolled.signing_key_preserved && rolled.legacy_tombstone_preserved);
  await capabilities(null);await newCall(false);
  console.log('Operations: ordinary call after rollback works; checking old and new encrypted data');
  await read(before);assert((await read(after))>0,'Data written after upgrade must survive rollback, not an old snapshot');
  assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),0);
  Object.assign(report,{baseline_source_commit:'c3e3f43',baseline_image_id:fixture.baseline,
    real_code_upgrade_and_rollback:true,same_named_volumes:true,screen_schema_migrated_1_to_2:true,
    additive_schema_not_downgraded:true,legacy_tombstone_preserved:true,
    consistent_backups_before_each_switch:true,signing_key_preserved:true,
    data_before_upgrade_and_after_upgrade_preserved:true,server_history_and_files_decrypted:true,
    ordinary_e2ee_voice_camera_before_after_each_switch:true,
    screen_off_on_and_quiescence_before_rollback:true,new_screen_generation_decrypted:true,
    old_server_has_no_screen_capability:true,no_automatic_capture:true,
    scope_of_rollback:'manual runbook through real Compose; production deploy coordinator/registry not exercised',
    production_registry_manifest:'NOT_TESTED',client_vault_preserved:true});
};
