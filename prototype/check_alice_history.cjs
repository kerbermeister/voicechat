// Read-only audit of retained demo profiles; never print credentials or room keys.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const root=path.join(__dirname,'..');
const privateRoot=path.join(root,'.prototype');
const accounts=JSON.parse(fs.readFileSync(path.join(privateRoot,'accounts.json')));
const matrix='http://localhost:8008/_matrix/client/v3/';
async function request(route,body,token) {
  const response=await fetch(matrix+route,{method:body ? 'POST':'GET',
    headers:{'Content-Type':'application/json',...(token ? {Authorization:'Bearer '+token}:{})},
    ...(body ? {body:JSON.stringify(body)}:{})});
  if(response.status===404) return null;
  assert.equal(response.status,200,'Matrix history audit request failed');
  return response.json();
}
(async()=>{
  const alice=await request('login',{type:'m.login.password',user:accounts.alice.username,password:accounts.alice.password});
  const sessions=new Map(); const events=[]; let backup;
  try {
    backup=await request('room_keys/version',undefined,alice.access_token);
    const rooms=(await request('joined_rooms',undefined,alice.access_token)).joined_rooms;
    // The reported inaccessible history is from the evening before October 22.
    const cutoff=Date.parse('2026-10-22T00:00:00+02:00');
    for(const room of rooms) {
      const result=await request('rooms/'+encodeURIComponent(room)+'/messages?dir=b&limit=100',undefined,alice.access_token);
      for(const event of result.chunk) {
        if(event.type!=='m.room.encrypted' || event.sender!==alice.user_id || event.origin_server_ts>=cutoff) continue;
        const sid=event.content.session_id;
        if(typeof sid==='string') {sessions.set(sid,room);events.push({room,sid,id:event.event_id,ciphertext:event.content.ciphertext});}
      }
    }
  } finally {await request('logout',{},alice.access_token);}
  assert(sessions.size>0,'No old encrypted sessions found in the inspected rooms');
  const profiles=[];
  for(const role of ['bob','carol']) {
    const directory=path.join(privateRoot,'demo-devices',role);
    const fixture=directory+'.json';
    if(!fs.existsSync(directory) || !fs.existsSync(fixture)) {profiles.push({role,retained:false});continue;}
    const vault=JSON.parse(fs.readFileSync(fixture));
    const context=await chromium.launchPersistentContext(directory,{
      executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,
      viewport:{width:900,height:700},args:['--disable-background-networking'],
    });
    try {
      const page=context.pages()[0] ?? await context.newPage();
      await page.goto('http://localhost:7357/manifest.json');
      await page.addScriptTag({url:'http://localhost:7357/vault.js'});
      await page.addScriptTag({url:'http://localhost:7357/pkg/vodozemac_bindings_dart.js'});
      const result=await page.evaluate(async ({profile,phrase,role,wanted,events})=>{
        const name='voicechat_probe_'+encodeURIComponent(profile);
        const dbName=name+'.encrypted';
        const available=await indexedDB.databases();
        if(!available.some(d=>d.name===dbName)) return {retained:false};
        const read=request=>new Promise((resolve,reject)=>{request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(new Error('Profile read failed'));});
        await voicechatVault.open(name,phrase,false);
        let db;
        try {
          db=await read(indexedDB.open(dbName));
          const client=db.transaction('box_client','readonly').objectStore('box_client');
          const raw=await read(client.get('user_id'));
          const user=JSON.parse(await voicechatVault.decrypt(name,'box_client','user_id',raw));
          if(user!=='@'+role+':voicechat.local') throw new Error('Unexpected retained account');
          const keys=await read(db.transaction('box_inbound_group_session','readonly').objectStore('box_inbound_group_session').getAllKeys());
          const matches=keys.filter(key=>wanted.includes(key));
          // Use the installed SDK's WASM without compiling or starting a chat client.
          await wasm_bindgen('http://localhost:7357/pkg/vodozemac_bindings_dart_bg.wasm');
          const unwrap=result=>{if(result[0]!==0) throw new Error('Cryptographic audit failed');return result[1];};
          const wire=wasm_bindgen;
          const pickleKey=new Uint8Array(32);
          pickleKey.set(new TextEncoder().encode(user).slice(0,32));
          let decryptedEvents=0;
          for(const event of events.filter(e=>matches.includes(e.sid))) {
            const raw=await read(db.transaction('box_inbound_group_session','readonly').objectStore('box_inbound_group_session').get(event.sid));
            const stored=JSON.parse(await voicechatVault.decrypt(name,'box_inbound_group_session',event.sid,raw));
            if(stored.room_id!==event.room) throw new Error('Session room mismatch');
            const session=unwrap(wire.wire__crate__bindings__vodozemac_inbound_group_session_from_pickle_encrypted(stored.pickle,pickleKey));
            // FRB 2.x encodes this opaque session as [[pointer, size]]; the call consumes its reference.
            if(!Array.isArray(session[0]) || typeof session[0][0]!=='number') throw new Error('Unsupported SDK binding');
            const plaintext=unwrap(wire.wire__crate__bindings__vodozemac_inbound_group_session_decrypt([session[0][0]],event.ciphertext));
            if(JSON.parse(plaintext[0]).room_id!==event.room) throw new Error('Decrypted room mismatch');
            decryptedEvents++;
          }
          return {retained:true,storedSessions:keys.length,matchingOldSessions:matches.length,decryptedEvents,
            matchingSessions:matches.map(sid=>({session:sid,room:events.find(e=>e.sid===sid).room,events:events.filter(e=>e.sid===sid).map(e=>e.id)}))};
        } finally {db?.close();await voicechatVault.close(name);}
      },{profile:vault.profile,phrase:vault.phrase,role,wanted:[...sessions.keys()],events});
      profiles.push({role,...result});
    } finally {await context.close();}
  }
  const report={date:'2026-10-22',oldEncryptedEvents:events.length,oldSessions:sessions.size,
    serverBackupExists:backup!==null,profiles};
  const destination=path.join(privateRoot,'alice-history-audit.json');
  fs.writeFileSync(destination,JSON.stringify(report,null,2)+'\n',{mode:0o600});
  console.log(JSON.stringify({...report,profiles:profiles.map(({matchingSessions,...counts})=>counts)}));
})().catch(error=>{console.error('History audit failed: '+error.name);process.exitCode=1;});
