// SS-11: disposable Matrix users, private production API/DB, real pinned SFU.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const {chromium}=require('playwright');
const media=require('./check_screen_calls.cjs');
const matrix='http://localhost:8008',ui='http://localhost:7363/';
const mode=process.argv[2];assert(['commands','keys','publish','faults'].includes(mode));
const excluded=process.argv[3]||'';
assert(mode==='faults' ? ['network','restart','kill_control','kill_sfu','pause_control','after_create','after_delete','lease','kick'].includes(excluded) :
  ['','member','device'].includes(excluded) && (!excluded || mode==='commands'));
if(mode==='faults' && !['after_create','after_delete','lease','kick'].includes(excluded)) process.env.VOICECHAT_SCREEN_CONTAINER='1';
const root=path.join(__dirname,'..');
const secrets=JSON.parse(fs.readFileSync(path.join(root,'.prototype/secrets.json')));
async function request(base,route,body,token,method=body ? 'POST' : 'GET') {
  const r=await fetch(base+route,{method,signal:AbortSignal.timeout(15000),
    headers:{'Content-Type':'application/json',...(token ? {Authorization:'Bearer '+token} : {})},
    ...(body ? {body:JSON.stringify(body)} : {})});
  return {status:r.status,body:await r.json()};
}
async function ok(...args) {const r=await request(...args);assert.equal(r.status,200,'Fixture request failed');return r.body;}
async function register(role) {
  const {nonce}=await ok(matrix,'/_synapse/admin/v1/register');
  const username='screen_negative_'+role+'_'+Date.now(),password=crypto.randomBytes(24).toString('base64url');
  const mac=crypto.createHmac('sha1',secrets.registration).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
  await ok(matrix,'/_synapse/admin/v1/register',{nonce,username,password,admin:false,mac});
  return {username,password,...await ok(matrix,'/_matrix/client/v3/login',{type:'m.login.password',user:username,password})};
}
async function cmd(page,data) {
  const result=await page.evaluate(data=>window.screenLab(data),data);
  assert(!result.error,'Lab command failed: '+data.action+' '+(result.kind||'')+' '+(result.step||''));return result;
}
async function until(check,message,ms=20000) {
  const end=Date.now()+ms;
  while(Date.now()<end) {if(await check())return;await new Promise(r=>setTimeout(r,100));}
  assert.fail(message);
}
function absent(generation) {
  execFileSync('python3',['-c',"import sys;sys.path.insert(0,'prototype');from screen_fixture import assert_room_absent;assert_room_absent(sys.stdin.read())"],
    {cwd:root,input:generation,stdio:['pipe','pipe','pipe']});
}
function updatePermission(generation,identity) {
  execFileSync('python3',['-c',`import json,sys,time,urllib.request
sys.path.insert(0,'prototype')
from token_server import jwt
data=json.load(sys.stdin);room=data['room']
token=jwt({'iss':'prototype','nbf':int(time.time())-5,'exp':int(time.time())+30,'video':{'roomAdmin':True,'room':room}})
req=urllib.request.Request('http://127.0.0.1:7880/twirp/livekit.RoomService/UpdateParticipant',json.dumps({'room':room,'identity':data['identity'],'permission':{'canSubscribe':True,'canPublish':True,'canPublishData':False,'canPublishSources':['SCREEN_SHARE']}}).encode(),{'Authorization':'Bearer '+token,'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=5) as response:response.read()`],
    {cwd:root,input:JSON.stringify({room:generation,identity}),stdio:['pipe','pipe','pipe']});
}
(async()=>{
  const accounts=[],pages=[],sources=[],bindings=new Map(),claims=new Map(),tokens=new Map(),logins=new Map(),wire=[],responses=[];
  let fixture,browser,failed=false;
  const report={result:'FAIL',run:new Date().toISOString(),mode,
    scope:'laboratory entrypoint using production controllers; real Matrix/Olm/SFU/tab capture; synthetic voice/camera',
    production_source_commit:execFileSync('git',['rev-parse','56efbb1'],{cwd:root,encoding:'utf8'}).trim(),android:'NOT_RUN',heavy_load:'NOT_RUN'};
  if(excluded) report[mode==='faults' ? 'fault' : 'excluded_trusted_device']=excluded;
  const started=performance.now();
  try {
    report.laboratory_source_sha256=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'apps/client/lib/lab_screen_security_main.dart'))).digest('hex');
    report.laboratory_js_sha256=crypto.createHash('sha256').update(Buffer.from(await (await fetch(ui+'main.dart.js')).arrayBuffer())).digest('hex');
    for(const role of ['a','b','outsider']) accounts.push(await register(role));
    process.env.VOICECHAT_ORIGINS=new URL(ui).origin;
    fixture=await require('./check_screen_faults.cjs').start();
    if(fixture.image)report.control_image_id=fixture.image;
    for(const peer of accounts.slice(1)) {
      await ok('http://localhost:8090','/contacts',{action:'policy',allow_direct:true},peer.access_token);
      const dm=await ok(matrix,'/_matrix/client/v3/createRoom',{preset:'private_chat',is_direct:true,invite:[peer.user_id],initial_state:[
        {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
        {type:'dev.voicechat.kind',state_key:'',content:{kind:'direct',owner:accounts[0].user_id,peer:peer.user_id}},
      ]},accounts[0].access_token);
      await ok('http://localhost:8090','/contacts',{action:'request',recipient:peer.user_id,room_id:dm.room_id},accounts[0].access_token);
      await ok(matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(dm.room_id)+'/join',{},peer.access_token);
    }
    const room=await ok(matrix,'/_matrix/client/v3/createRoom',{preset:'private_chat',invite:accounts.slice(1).map(a=>a.user_id),initial_state:[
      {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
    ]},accounts[0].access_token);
    for(const peer of accounts.slice(1)) await ok(matrix,'/_matrix/client/v3/rooms/'+encodeURIComponent(room.room_id)+'/join',{},peer.access_token);
    browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:[
      '--enable-usermedia-screen-capturing','--auto-select-tab-capture-source-by-title=VoiceChat Screen Source','--autoplay-policy=no-user-gesture-required']});
    const session=crypto.randomUUID();
    const loginAccounts=[...accounts.slice(0,2),...(excluded && mode==='commands' ? [accounts[excluded==='member' ? 2 : 0]] : [])];
    for(const [i,account] of loginAccounts.entries()) {
      const context=await browser.newContext({permissions:['microphone','camera'],viewport:{width:1280,height:1000}});
      await context.addInitScript(media.syntheticMedia);
      await context.addInitScript(()=>{window.callPeers=[];window.RTCPeerConnection=new Proxy(window.RTCPeerConnection,{construct(target,args){
        const pc=Reflect.construct(target,args);window.callPeers.push(pc);return pc;}});
        window.screenLabSockets=[];window.WebSocket=new Proxy(window.WebSocket,{construct(target,args){
          const socket=Reflect.construct(target,args);window.screenLabSockets.push(socket);return socket;}});
        // Observe the real cryptor worker boundary, in memory only. Never log this array.
        window.screenLabKeys=[];const post=Worker.prototype.postMessage;
        Worker.prototype.postMessage=function(message,...args){
          if(message?.msgType==='setKey') window.screenLabKeys.push({id:message.keyProviderId,owner:message.participantId,key:message.key});
          return post.call(this,message,...args);
        };
      });
      await context.route('**/fixture.json',route=>route.fulfill({json:{profile:session+'-'+i,
        username:account.username,password:account.password,room:room.room_id,session,api:fixture.base,livekit:fixture.livekit}}));
      const page=await context.newPage();pages.push(page);
      page.on('request',r=>{
        if(r.url().startsWith(fixture.base) || r.url().includes('/sendToDevice/')) wire.push(r.postData()||'');
      });
      await page.exposeFunction('screenLabObserve',record=>{
        if(record.login){logins.set(page,record.body);return;}
        const {action,body,auth,request:command}=record;
        if(action==='bind')bindings.set(page,{...body,auth,request:command});
        if(action==='claim' && (!claims.has(page) || command.expected_revision>=claims.get(page).command.expected_revision))
          claims.set(page,{command,response:body});
        if(action==='token' && (!tokens.has(page) || body.revision>=tokens.get(page).revision))
          tokens.set(page,{...body,request:command});
      });
      await page.addInitScript(()=>{
        const fetch=window.fetch.bind(window);
        window.fetch=async(...args)=>{
          const request=new Request(...args);
          const watched=request.method==='POST' && (/\/screen\/(?:bind|[^/]+\/(?:claim|token))$/.test(request.url) || request.url.endsWith('/_matrix/client/v3/login'));
          const body=watched ? request.clone().text() : null;
          const response=await fetch(request);
          if(watched && [200,202].includes(response.status)) {
            const login=request.url.endsWith('/_matrix/client/v3/login');
            await window.screenLabObserve({login,action:request.url.split('/').pop(),
              body:await response.clone().json(),auth:request.headers.get('authorization'),
              request:login ? null : JSON.parse(await body)});
          }
          return response;
        };
      });
      page.on('response',response=>{
        if(response.url().startsWith(fixture.base) && response.url().includes('/screen/')) {
          responses.push({page:i,action:response.url().split('/').pop(),status:response.status(),method:response.request().method()});
          if(response.status()>=400)console.log('Private control',response.url().split('/').pop(),response.status());
        }
      });
      await page.goto(ui);await page.getByText('ready',{exact:true}).waitFor({timeout:60000});
      if(i<2) sources.push(await media.captureSource(page,i));
    }
    const [a,b]=pages;
    const identities=await Promise.all(pages.map(page=>cmd(page,{action:'identity'})));
    for(const page of pages) for(const identity of identities) await cmd(page,{action:'trust',...identity});
    await Promise.all(pages.slice(0,2).map(page=>cmd(page,{action:'connect'})));
    try {await until(()=>bindings.size===2,'Both screen bindings required');}
    catch(error) {console.log('Binding setup diagnostics',JSON.stringify({observed:bindings.size,responses:responses.slice(0,12)}));throw error;}
    const button=(page,name)=>page.getByRole('button',{name,exact:true});
    async function start(index) {
      await media.selectSource(sources,index);const page=pages[index];await page.bringToFront();
      const previous=tokens.get(page)?.generation;
      const previousCommand=claims.get(page)?.command.request_id;
      await button(page,await button(page,'Показать экран').isVisible() ? 'Показать экран' : 'Перехватить экран').click();
      await button(page,'Остановить показ').waitFor({timeout:20000});
      try {await until(()=>tokens.get(page)?.role==='publisher' && tokens.get(page).generation!==previous,'Publisher grant required');}
      catch(error) {console.log('Publisher observer diagnostics',JSON.stringify({page:index,role:tokens.get(page)?.role,changed:tokens.get(page)?.generation!==previous,revision:tokens.get(page)?.revision,responses:responses.filter(r=>r.page===index).slice(-12)}));throw error;}
      await until(()=>claims.get(page)?.command.request_id && claims.get(page).command.request_id!==previousCommand,'Claim request required');
      return tokens.get(page);
    }
    async function api(page,suffix,body) {return request(fixture.base,'/screen/'+bindings.get(page).binding_id+'/'+suffix,body,bindings.get(page).auth.slice(7));}
    const ctx={a,b,pages,sources,accounts,fixture,report,cmd,until,media,button,start,api,identities,bindings,claims,tokens,request,absent,updatePermission,wire,logins,room:room.room_id,session};
    await require('./check_screen_security_'+mode+'.cjs')(ctx);
    report.result='PASS';
    console.log('PASS: '+(mode==='faults' ? 'SS-10/SS-16 '+excluded : 'SS-11 '+mode));
  } catch(error) {
    failed=true;throw error;
  } finally {
    let cleanupFailed=false;
    if(browser) {
      for(const page of pages) await cmd(page,{action:'close'}).catch(()=>{});
      await browser.close().catch(()=>{cleanupFailed=true;});
    }
    if(fixture) await fixture.close().catch(()=>{cleanupFailed=true;});
    for(const a of accounts) {
      try {
        const r=await request(matrix,'/_matrix/client/v3/account/deactivate',{
          auth:{type:'m.login.password',identifier:{type:'m.id.user',user:a.user_id},password:a.password},erase:true},a.access_token);
        if(r.status!==200)cleanupFailed=true;
      } catch (_) {cleanupFailed=true;}
    }
    report.cleanup_completed=!cleanupFailed;
    if(cleanupFailed)report.result='FAIL';
    report.elapsed_seconds=(performance.now()-started)/1000;
    fs.writeFileSync(path.join(__dirname,'verified-screen-security-'+mode+(excluded ? '-'+excluded : '')+'-run.json'),JSON.stringify(report,null,2)+'\n');
    if(cleanupFailed && !failed)throw new Error('Private test fixture cleanup failed');
  }
})().catch(error=>{console.error(error.stack);process.exitCode=1;})
  .finally(()=>process.exit(process.exitCode || 0));
