const assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');

module.exports=async c=>{
  const {a,b,api,cmd,start,media,until,report,bindings,claims,identities,fixture,request}=c;
  await until(async()=>{const r=await media.audio(b);return r.packets>0 && r.frames>0;},'Real base voice/camera required');
  const original=await start(0);await media.pixels(b);
  const oldClaim=claims.get(a).command;
  const owner=identities[0].user+'/'+identities[0].device;
  c.updatePermission(original.generation,owner);
  let refreshed;
  await until(async()=>{refreshed=(await cmd(a,{action:'engineToken'})).token;return refreshed && refreshed!==original.token;},'Actual SDK refresh required');
  for(const token of [original.token,refreshed]) {
    const payload=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));
    assert(payload.video.room===original.generation && payload.sub===owner);
    assert(payload.exp>Date.now()/1000,'Retained JWT must be unexpired');
  }
  const before=await media.audio(a),winner=await start(1);await media.pixels(a,true,[201,97,49]);
  c.absent(original.generation);
  const state=()=>api(b,'state');
  const current=(await state()).body;
  const attempted=[];
  async function reject(label,page,path,body,expected) {
    const r=await api(page,path,body);assert.equal(r.status,expected,label);attempted.push(label);
    const now=(await state()).body;
    assert(now.generation===current.generation && now.owner_identity===current.owner_identity && now.revision===current.revision,'Rejected command must not replace winner');
  }
  const lease=bindings.get(a).lease_id;
  await reject('late old-owner stop',a,'stop',{...oldClaim,request_id:randomUUID()},409);
  await reject('late new claim with old revision',a,'claim',{...oldClaim,request_id:randomUUID()},409);
  await reject('request id reused with changed body',a,'claim',{...oldClaim,expected_revision:current.revision},409);
  const repeated=await api(a,'claim',oldClaim);
  assert.equal(repeated.status,200);
  assert(repeated.body.snapshot.generation===current.generation && repeated.body.snapshot.owner_identity===current.owner_identity,'Idempotent old claim must only return receipt, not regain ownership');
  attempted.push('old successful claim replay is inert');
  await reject('old-generation token',a,'token',original.request,409);
  const token={protocol_version:1,lease_id:lease,expected_revision:current.revision,generation:current.generation};
  await reject('forged generation',a,'token',{...token,generation:'screen-'+'f'.repeat(48)},409);
  await reject('another device lease',a,'token',{...token,lease_id:bindings.get(b).lease_id},403);
  await reject('body identity spoof',a,'token',{...token,actor_identity:current.owner_identity},400);
  for(const account of [c.accounts[0],c.accounts[2]]) {
    const response=await request(fixture.base,'/screen/'+current.binding_id+'/token',token,account.access_token);
    assert.equal(response.status,404,'Chat member / other device must not obtain grant');
  }
  const group={...bindings.get(a).request,call_session:'other-'+randomUUID()};
  const denied=await request(fixture.base,'/screen/bind',group,bindings.get(a).auth.slice(7));
  assert([403,410].includes(denied.status),'Other call has no valid group lease');
  const pending=await request(fixture.base,'/screen/bind',{protocol_version:1,room_id:c.room,call_session:randomUUID(),transport:'direct',
    peer:{user_id:identities[1].user,device_id:identities[1].device}},bindings.get(a).auth.slice(7));
  assert.equal(pending.status,200);assert.equal(pending.body.binding_state,'pending');
  const direct=await request(fixture.base,'/screen/'+pending.body.binding_id+'/token',{...token,lease_id:pending.body.lease_id},bindings.get(a).auth.slice(7));
  assert.equal(direct.status,403,'Direct binding requires second device confirmation');
  await request(fixture.base,'/screen/unbind',{protocol_version:1,binding_id:pending.body.binding_id,lease_id:pending.body.lease_id,request_id:randomUUID()},bindings.get(a).auth.slice(7));
  for(const token of [original.token,refreshed]) {
    const r=await cmd(a,{action:'rawJoin',token});assert.equal(r.connected,false,'Independent room must not reconnect using retained JWT');
  }
  const viewer=await api(a,'token',token);assert.equal(viewer.status,200);
  const grant=JSON.parse(Buffer.from(viewer.body.token.split('.')[1],'base64url')).video;
  assert(grant.room===winner.generation && !grant.canPublish && !grant.canPublishData);
  const pieces=viewer.body.token.split('.'),forged=JSON.parse(Buffer.from(pieces[1],'base64url'));
  forged.sub=current.owner_identity;forged.video.canPublish=true;
  const forgedToken=[pieces[0],Buffer.from(JSON.stringify(forged)).toString('base64url'),pieces[2]].join('.');
  assert.equal((await cmd(a,{action:'rawJoin',token:forgedToken})).connected,false,'Changed JWT identity/grant must fail signature verification');
  await media.pixels(a,true,[201,97,49]);const after=await media.audio(a);
  assert(after.packets>before.packets && after.frames>before.frames);
  assert.deepEqual(after.voicePeers,before.voicePeers);
  report.commands=attempted;report.original_and_refreshed_unexpired_jwt_reconnect_denied=true;
  report.old_owner_only_receives_viewer_grant=true;report.chat_member_and_unselected_device_denied=true;
  report.direct_without_mutual_confirmation_denied=true;report.other_call_denied=true;
  report.winner_pixels_and_voice_camera_continue=true;
  report.tampered_jwt_identity_and_publisher_grant_denied=true;
  if(c.pages[2]) {
    const extra=c.pages[2];await until(()=>c.logins.has(extra),'Additional SDK login required');
    const recipient=identities[2],marker='excluded-device-positive-probe';
    assert(recipient.device!==identities[0].device,'Fixture must use a different actual device');
    await cmd(a,{action:'send',user:recipient.user,device:recipient.device,
      type:'dev.voicechat.screen_security_probe',content:{lab_case:marker}});
    await until(async()=>(await cmd(extra,{action:'inspect'})).received.includes(marker),
      'Excluded device must actually decrypt a harmless positive-control Olm message');
    const r=await request(fixture.base,'/screen/'+current.binding_id+'/token',token,c.logins.get(extra).access_token);
    assert.equal(r.status,404,'Even a trusted crypto-capable device outside the call must not receive a grant');
    const observed=await cmd(extra,{action:'gate',enabled:false});
    assert.equal(observed.received_generations.length,0,'Excluded trusted device must not receive any screen key');
    report.additional_sdk_device_keys_manually_verified=true;
    report.additional_sdk_device_without_call_denied=true;
    report.additional_sdk_device_received_no_screen_key=true;
    report.additional_sdk_device_decrypted_positive_control=true;
  }
};
