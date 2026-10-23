const assert=require('node:assert/strict');

module.exports=async c=>{
  const {a,b,start,cmd,media,until,fixture,report}=c;
  const fault=report.fault;
  const first=await start(0);await media.pixels(b);
  console.log('Fault fixture: real encrypted screen visible');
  const captures=await a.evaluate(()=>window.screenCaptureTracks.length);
  async function stopped() {
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'),null,{timeout:35000});
    await media.pixels(b,false);
    assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),captures,'No automatic new capture');
  }
  if(['after_create','after_delete'].includes(fault)) {
    const before=await media.audio(b);
    await fixture.command(fault);
    const winner=await start(1);
    await media.pixels(a,true,[201,97,49]);
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'));
    c.absent(first.generation);
    const state=await fixture.command('status');
    assert.equal(state.sfu_fault_injected,true);assert.equal(state.pending_commands,0);
    assert.equal(state.retired_rooms,0);assert.equal(state.sessions.active,1);
    assert.notEqual(winner.generation,first.generation);
    const after=await media.audio(b);
    assert(after.packets>before.packets && after.frames>before.frames);
    assert.deepEqual(after.voicePeers,before.voicePeers);
    report.real_sfu_committed_before_reply_lost=true;report.pending_intent_recovered=true;
    report.exactly_one_active_generation=true;report.old_owner_stopped_and_sees_winner=true;
    report.voice_camera_preserved=true;
  } else if(fault==='lease') {
    const pattern=fixture.base+'/screen/**',block=route=>route.abort();
    const before=await media.audio(b);
    await a.route(pattern,block);
    try {
      await stopped();
      await until(async()=>{
        const r=await c.api(b,'state');return r.status===200 && r.body.generation!==first.generation;
      },'Server must expire the silent screen lease',15000);
      c.absent(first.generation);
      const claims=JSON.parse(Buffer.from(first.token.split('.')[1],'base64url'));
      assert(Date.now()/1000<claims.exp);
      assert.equal((await cmd(a,{action:'rawJoin',token:first.token})).connected,false);
      assert(Date.now()/1000<claims.exp);
    } finally {await a.unroute(pattern,block);}
    await start(1);await media.pixels(b,false);
    const after=await media.audio(b);
    assert(after.packets>before.packets && after.frames>before.frames);
    assert.deepEqual(after.voicePeers,before.voicePeers);
    assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),captures);
    report.real_silent_lease_expired=true;report.stale_authorization_stops_capture=true;
    report.unexpired_old_jwt_rejected=true;report.remaining_peer_can_start=true;
    report.no_automatic_capture=true;report.voice_camera_preserved=true;
  } else if(fault==='network') {
    // Close actual SFU WebSockets, then block HTTP/new connections for A.
    // This is a signaling/control interruption, not a claim of UDP packet loss.
    const previousGrant=c.tokens.get(a);
    await a.context().setOffline(true);
    const closed=await a.evaluate(()=>{
      const sockets=window.screenLabSockets.filter(s=>s.readyState===WebSocket.OPEN);
      sockets.forEach(s=>s.close(4000,'local fault fixture'));return sockets.length;
    });
    assert(closed>=2,'Actual voice and screen signaling sockets must be open');
    await new Promise(r=>setTimeout(r,3000));
    await a.context().setOffline(false);
    await until(()=>c.tokens.get(a)!==previousGrant,'Fresh grant after actual signaling reconnect');
    await media.pixels(b);
    const frameCount=(await cmd(b,{action:'inspect'})).frames;
    await until(async()=>{
      const r=await cmd(b,{action:'inspect'});return r.decoded && r.frames>frameCount;
    },'Fresh authorized subscription after actual SDK reconnect');
    assert.equal(await a.evaluate(()=>window.screenCaptureTracks.filter(t=>t.readyState==='live').length),1);
    assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),captures);
    const grant=c.tokens.get(a);
    assert.equal(grant.generation,first.generation,'Short disconnect must not seize another generation');
    // Lose ownership while disconnected; rejoining must follow B, not reclaim A.
    await a.context().setOffline(true);
    const winner=await start(1);
    assert.notEqual(winner.generation,first.generation);
    await a.context().setOffline(false);
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'),null,{timeout:30000});
    await media.pixels(a,true,[201,97,49]);
    assert.equal(c.tokens.get(a).role,'viewer');
    assert.equal(c.tokens.get(a).generation,winner.generation);
    assert.equal(await a.evaluate(()=>window.screenCaptureTracks.length),captures);
    report.short_disconnect_preserves_capture_and_generation=true;
    report.reconnected_loser_is_viewer_and_sees_winner=true;
    report.no_automatic_reclaim_or_capture=true;
  } else {
    const started=performance.now(),state=await fixture.command(fault);
    console.log('Fault fixture: '+fault+' completed');
    if(fault!=='restart') {
      assert.equal(state.exit_code,1);assert.equal(state.running,false);
      await stopped();
      await fixture.command('restart');
    } else await stopped();
    const recovered=await fixture.command('status');
    assert.equal(recovered.sessions.active||0,0);assert.equal(recovered.pending_commands,0);
    assert.equal(recovered.retired_rooms,0);
    await fixture.command('absent '+first.generation);
    const claims=JSON.parse(Buffer.from(first.token.split('.')[1],'base64url'));
    assert(Date.now()/1000<claims.exp,'Probe old JWT before expiry');
    assert.equal((await cmd(a,{action:'rawJoin',token:first.token})).connected,false);
    assert(Date.now()/1000<claims.exp);
    report.fault_seconds=(performance.now()-started)/1000;
    report.supervisor_stops_both_children=fault!=='restart';
    report.live_screen_capture_stopped=true;report.old_frame_hidden=true;
    report.restart_clears_persisted_leases_and_rooms=true;
    report.unexpired_old_jwt_rejected=true;report.no_automatic_capture=true;
    report.group_voice_during_shared_sfu_outage='interrupted; not claimed to continue';
  }
};
