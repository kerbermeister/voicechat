// Faults affect only a private screen API/DB; the shared Matrix/SFU stay running.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawn,execFileSync}=require('node:child_process');
const {createInterface}=require('node:readline');

exports.start=async()=>{
  const secrets=JSON.parse(fs.readFileSync(path.join(__dirname,'../.prototype/secrets.json')));
  const child=spawn('python3',[path.join(__dirname,process.env.VOICECHAT_SCREEN_CONTAINER==='1' ? 'screen_container_fixture.py' : 'screen_fault_fixture.py')],{
    detached:true,stdio:['pipe','pipe','inherit'],env:{...process.env,
      VOICECHAT_LIVEKIT_SECRET:secrets.livekit,VOICECHAT_POLICY_SECRET:secrets.policy},
  });
  const exited=new Promise(resolve=>child.once('exit',code=>resolve(code)));
  const lines=createInterface({input:child.stdout})[Symbol.asyncIterator]();
  async function read() {
    const line=await lines.next();assert(!line.done,'Private fault fixture exited');
    const result=JSON.parse(line.value);
    assert(Number.isInteger(result.api_port) && result.api_port>0 && result.api_port<65536);
    return result;
  }
  let current;
  try {current=await read();} catch(error) {child.stdin.end();await exited;throw error;}
  return {
    get base(){return 'http://127.0.0.1:'+current.api_port;},
    get livekit(){return current.livekit_url;},
    get image(){return current.image_id;},
    async command(action){child.stdin.write(action+'\n');current=await read();return current;},
    async close(){child.stdin.end();assert.equal(await exited,0,'Private fixture cleanup failed');},
  };
};

exports.check=async({a,b,button,sources,selectSource,pixels,audio,fixture})=>{
  const mode=process.env.VOICECHAT_SCREEN_FAULT_TEST;
  assert(['matrix','restart'].includes(mode));
  const report={result:'FAIL',run:new Date().toISOString(),scope:'private real screen control API/SQLite; shared Matrix/SFU not stopped',fault:mode};
  const tokenReply=a.waitForResponse(r=>r.status()===200 && /\/screen\/[^/]+\/token$/.test(r.url()));
  await selectSource(sources,0);await a.bringToFront();await button(a,'Показать экран').click();
  const response=await tokenReply,saved=await response.json(),headers=await response.request().allHeaders();
  const claims=JSON.parse(Buffer.from(saved.token.split('.')[1],'base64url').toString());
  await button(a,'Остановить показ').waitFor({timeout:15000});await pixels(b);
  const before=await audio(b),started=performance.now();
  let probe;
  try {
    await fixture.command(mode==='matrix' ? 'matrix_off' : 'restart');
    await a.waitForFunction(()=>window.screenCaptureTracks.every(t=>t.readyState==='ended'),null,{timeout:mode==='matrix' ? 28000 : 15000});
    await pixels(b,false);
    let state;
    while(performance.now()-started<35000) {
      state=await fixture.command('status');
      if(!state.sessions.active && state.retired_rooms===0) break;
      await a.waitForTimeout(300);
    }
    assert(!state.sessions.active && state.retired_rooms===0,'Expired or recovered room must be retired within 35 seconds');
    execFileSync('python3',['-c',"import sys;sys.path.insert(0,'prototype');from screen_fixture import assert_room_absent;assert_room_absent(sys.stdin.read())"],
      {cwd:path.join(__dirname,'..'),input:saved.generation,stdio:['pipe','pipe','pipe']});
    const denied=await fetch(fixture.base+new URL(response.url()).pathname,{method:'POST',
      headers:{'Content-Type':'application/json',Authorization:headers.authorization},body:response.request().postData(),signal:AbortSignal.timeout(5000)});
    assert(mode==='matrix' ? denied.status===503 : [403,404,410].includes(denied.status));
    assert(Date.now()/1000<claims.exp);
    probe=await a.context().newPage();
    await probe.route('**/fixture.json',route=>route.fulfill({json:{
      key:Buffer.alloc(32).toString('base64'),screen_wrong:saved.token,camera_wrong:saved.token,
    }}));
    await probe.goto(process.env.VOICECHAT_SCREEN_PROBE_URL || 'http://localhost:7362/?role=wrong');
    await probe.getByText(/^failed:/).waitFor({timeout:15000});
    assert(Date.now()/1000<claims.exp,'Reject the saved JWT before its expiry');
    if(mode==='matrix') await fixture.command('matrix_on');
    await b.bringToFront();const after=await audio(b);
    assert.deepEqual(after.voicePeers,before.voicePeers);
    assert(after.packets>before.packets && after.frames>before.frames,'Direct voice/camera must continue through screen fault');
    assert.equal(await a.evaluate(()=>window.screenCaptureTracks.filter(t=>t.readyState==='live').length),0);
    report.result='PASS';report.capture_stopped=true;report.old_frame_hidden=true;
    report.old_room_deleted=true;report.unexpired_old_jwt_rejected=true;
    report.voice_and_camera_continue=true;report.voice_connections_unchanged=true;
    report.no_automatic_capture_restart=true;report.retired_rooms=0;
    console.log('PASS: isolated '+mode+' fault cuts live encrypted screen, rejects old JWT and preserves direct voice/camera');
  } finally {
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-'+mode+'-fault-run.json'),JSON.stringify(report,null,2)+'\n');
    if(probe) await probe.close();
    if(mode==='matrix') await fixture.command('matrix_on');
  }
};
