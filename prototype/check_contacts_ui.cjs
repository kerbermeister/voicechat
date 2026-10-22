// Two independent browsers, disposable users; never log credentials or vault contents.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {chromium} = require('playwright');
const root = path.join(__dirname, '..');
const webUrl=process.env.VOICECHAT_UI_URL || 'http://localhost:7357/';
const matrixUrl=process.env.VOICECHAT_MATRIX_URL || 'http://localhost:8008';
const apiUrl=process.env.VOICECHAT_API_URL || 'http://localhost:8090';
const secretsFile=process.env.VOICECHAT_SECRETS_FILE || path.join(root,'.prototype/secrets.json');
const video = process.env.VOICECHAT_VIDEO_TEST === '1';
const network = process.env.VOICECHAT_NETWORK_TEST === '1';
const textOnly = process.env.VOICECHAT_TEXT_ONLY === '1';
const callButton = video ? 'Видеозвонок' : 'Голосовой звонок';
fs.mkdirSync(path.join(root,'.prototype/ui'),{recursive:true});

async function request(base, route, body, token, method = body ? 'POST' : 'GET') {
  const response = await fetch(base + route, {
    method, signal:AbortSignal.timeout(15000),
    headers: {'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {})},
    ...(body ? {body:JSON.stringify(body)} : {}),
  });
  assert.equal(response.status, 200, route);
  return response.json();
}

async function register(role) {
  const base = matrixUrl;
  const route = '/_synapse/admin/v1/register';
  const {nonce} = await request(base, route);
  const username = `consent_ui_${role}_${Date.now()}`;
  const password = crypto.randomBytes(24).toString('base64url');
  const secret = JSON.parse(fs.readFileSync(secretsFile)).registration;
  const mac = crypto.createHmac('sha1',secret).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
  await request(base, route, {nonce,username,password,admin:false,mac});
  const session = await request(base,'/_matrix/client/v3/login',{type:'m.login.password',user:username,password});
  return {username,password,...session};
}

(async () => {
  const alice = await register('alice'), bob = await register('bob'), charlie = await register('charlie');
  await request(apiUrl,'/contacts',{action:'policy',allow_direct:false},bob.access_token);
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:textOnly ? ['--mute-audio','--autoplay-policy=no-user-gesture-required'] : ['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--autoplay-policy=no-user-gesture-required']});
  const deadline=process.env.VOICECHAT_LINKS_ONLY==='1' ? setTimeout(()=>{console.error('Focused links deadline exceeded'); browser.close().catch(()=>{});},90000) : process.env.VOICECHAT_SCHEDULE_TEST==='1' ? setTimeout(()=>{console.error('Scheduled UI deadline exceeded'); browser.close().catch(()=>{});},360000) : null;
  const pages=[];
  let sensitiveVerification=false;
  try {
    const fill = async (page, name, value) => {
      await page.bringToFront();
      const field=page.getByRole('textbox',{name,exact:true});
      for(let i=0;i<100 && !await field.isEditable();i++) await page.waitForTimeout(100);
      await field.click(); await page.waitForTimeout(200);
      await page.keyboard.press('ControlOrMeta+A');
      if (value) await page.keyboard.insertText(value); else await page.keyboard.press('Backspace');
      await page.waitForTimeout(150);
      assert.equal(await field.inputValue()===value,true,`Text input did not commit: ${name}`);
      await page.keyboard.press('Tab');
    };
    const button=(page,name)=>page.getByRole('button',{name,exact:true});
    async function waitForAnnouncement(page, text) {
      for(let i=0;i<100;i++) {
        if((await page.locator('body').ariaSnapshot()).includes(text)) return;
        await page.waitForTimeout(200);
      }
      assert.fail('Expected interface text is not announced: '+text);
    }
    async function videoFrames(page) {
      await page.bringToFront();
      for(let i=0;i<100;i++) {
        const ready=await page.locator('video').evaluateAll(nodes=>nodes.filter(v=>v.getBoundingClientRect().width>1 && v.getBoundingClientRect().height>1 && v.videoWidth>0 && v.videoHeight>0 && v.readyState>=2 && v.srcObject?.getVideoTracks().some(t=>t.readyState==='live' && t.enabled)).length);
        if(ready>=2) {
          const fresh=await page.locator('video').evaluateAll(nodes=>Promise.all(nodes.filter(v=>v.getBoundingClientRect().width>1 && v.getBoundingClientRect().height>1).map(v=>new Promise(resolve=>{
            const timeout=setTimeout(()=>resolve(false),5000);
            v.requestVideoFrameCallback(()=>{clearTimeout(timeout);resolve(true);});
          }))));
          assert(fresh.length>=2 && fresh.every(Boolean),'Both visible videos must deliver a new decoded frame');
          return;
        }
        await page.waitForTimeout(200);
      }
      assert.fail('Local and remote video must both decode frames');
    }
    async function toggleCamera(page) {
      for (const label of ['Выключить камеру','Включить камеру']) {
        const control=button(page,label);
        await control.waitFor();
        for(let i=0;i<100 && !await control.isEnabled();i++) await page.waitForTimeout(100);
        const box=await control.boundingBox();
        await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
        await page.mouse.move(5,5);
        await button(page,label==='Выключить камеру' ? 'Включить камеру' : 'Выключить камеру').waitFor();
        if(label==='Выключить камеру') {
          await page.waitForFunction(()=>window.callPeers.every(pc=>pc.getSenders().every(s=>s.track?.kind!=='video' || s.track.readyState==='ended' || !s.track.enabled)));
        }
      }
      for(let i=0;i<100 && !await button(page,'Выключить камеру').isEnabled();i++) await page.waitForTimeout(100);
    }
    async function qualityCheck(sender, receiver) {
      await sender.bringToFront();
      await button(sender,'Авто').click();
      fs.writeFileSync(path.join(root,'.prototype/ui/quality-menu.txt'),await sender.locator('body').ariaSnapshot());
      await sender.screenshot({path:path.join(root,'.prototype/ui/quality-menu.png')});
      await sender.getByRole('menuitem',{name:'Низкое',exact:true}).click();
      await sender.mouse.move(5,5);
      await button(sender,'Низкое').waitFor();
      await sender.waitForFunction(()=>{
        const senders=window.callPeers.flatMap(pc=>pc.getSenders()).filter(s=>s.track?.kind==='video' && s.track.readyState==='live');
        return senders.length && senders.every(s=>s.getParameters().encodings?.every(e=>e.maxBitrate<=150000 && e.maxFramerate<=15));
      });
      await receiver.waitForFunction(()=>{
        const ids=window.callPeers.flatMap(pc=>pc.getReceivers()).filter(r=>r.track.kind==='video' && r.track.readyState==='live').map(r=>r.track.id);
        function videos(root) { return [...root.querySelectorAll('video'), ...[...root.querySelectorAll('*')].filter(el=>el.shadowRoot).flatMap(el=>videos(el.shadowRoot))]; }
        return videos(document).some(v=>ids.includes(v.srcObject?.getVideoTracks()[0]?.id) && v.videoWidth>0 && v.videoWidth<=320 && v.videoHeight<=180);
      });
      await sender.bringToFront();
      await button(sender,'Низкое').click();
      await sender.getByRole('menuitem',{name:'Авто',exact:true}).click();
      await sender.mouse.move(5,5);
      await button(sender,'Авто').waitFor();
      await videoFrames(sender); await videoFrames(receiver);
    }
    async function networkCheck(sender, receiver, transport) {
      const resultPath=path.join(root,`.prototype/video-network-${transport}.json`);
      fs.rmSync(resultPath,{force:true});
      async function sample() {
        const inbound=transport==='group';
        return (inbound ? receiver : sender).evaluate(async inbound=>{
          const rows=[];
          for(const pc of window.callPeers.filter(pc=>pc.connectionState!=='closed')) {
            for(const stat of (await pc.getStats()).values()) {
              if(stat.type===(inbound ? 'inbound-rtp' : 'outbound-rtp') && stat.kind==='video') rows.push({id:stat.id,bytes:inbound ? stat.bytesReceived : stat.bytesSent,frames:inbound ? stat.framesDecoded : stat.framesEncoded,width:stat.frameWidth ?? 0,height:stat.frameHeight ?? 0,reason:stat.qualityLimitationReason ?? ''});
            }
          }
          return {at:performance.now(),rows};
        },inbound);
      }
      await sender.waitForTimeout(8000);
      const before=await sample();
      await sender.waitForTimeout(3000);
      const normal=await sample();
      const container=execFileSync('docker',['compose','-f',path.join(root,'prototype/compose.yaml'),'ps','-q',transport==='direct' ? 'turn' : 'livekit'],{encoding:'utf8',timeout:15000}).trim();
      assert(/^[a-f0-9]{64}$/.test(container),'Own local media container required');
      const tc=(...args)=>execFileSync('docker',['run','--rm','--cap-add','NET_ADMIN','--network','container:'+container,'voicechat-netem:test',...args],{encoding:'utf8',timeout:15000});
      let shaped=false;
      let constrained, reduced;
      try {
        tc('qdisc','add','dev','eth0','root','netem','delay','60ms','loss','8%','limit','40','rate','384kbit');
        shaped=true;
        assert(tc('qdisc','show','dev','eth0').includes('netem'),'Container network shaping was not installed');
        await sender.waitForTimeout(15000);
        constrained=await sample();
        await sender.waitForTimeout(3000);
        reduced=await sample();
        assert(await button(sender,'Завершить').isVisible(),'Call ended during packet loss');
      } finally {
        if(shaped) tc('qdisc','del','dev','eth0','root');
      }
      function rate(first,last,key) {
        return last.rows.reduce((sum,row)=>{
          const previous=first.rows.find(p=>p.id===row.id);
          return sum+(previous ? Math.max(0,row[key]-previous[key]) : 0);
        },0)/((last.at-first.at)/1000);
      }
      const baselineBitrate=rate(before,normal,'bytes')*8;
      const constrainedBitrate=rate(constrained,reduced,'bytes')*8;
      const resized=reduced.rows.some(row=>normal.rows.some(previous=>previous.id===row.id && (row.width<previous.width || row.height<previous.height)));
      const baselineFps=rate(before,normal,'frames'), constrainedFps=rate(constrained,reduced,'frames');
      const adapted=resized || constrainedBitrate<baselineBitrate*.8 || constrainedFps<baselineFps*.8;
      const metrics={result:adapted ? 'ADAPTED' : 'FAIL',transport,emulator:'Docker media container egress netem',egress_limit_kbit:384,baseline_bitrate:Math.round(baselineBitrate),constrained_bitrate:Math.round(constrainedBitrate),baseline_fps:baselineFps,constrained_fps:constrainedFps,resized,normal:normal.rows,reduced:reduced.rows,packet_loss_percent:8,http_outage_seconds:4};
      fs.writeFileSync(resultPath,JSON.stringify(metrics));
      assert(adapted,'Auto did not reduce video load under constrained WebRTC bandwidth');
      await videoFrames(sender); await videoFrames(receiver);
      await sender.context().setOffline(true);
      await sender.waitForTimeout(4000);
      await sender.context().setOffline(false);
      await videoFrames(sender); await videoFrames(receiver);
      assert(await button(sender,'Авто').isVisible(),'Network recovery lost the selected Auto mode');
      fs.writeFileSync(resultPath,JSON.stringify({...metrics,result:'PASS'}));
      console.log(`PASS: ${transport} WebRTC adaptation and network recovery`);
    }
    async function createGroup(page, name, peer) {
      await page.getByText('Группы',{exact:true}).click();
      await button(page,'Создать группу').click();
      await fill(page,'Поиск пользователей',peer.username); await button(page,'Найти').click();
      await page.getByRole('checkbox',{name:`${peer.username} ${peer.user_id}`,exact:true}).click();
      await button(page,'Добавить').click();
      const input=page.getByRole('alertdialog').getByRole('textbox');
      await input.click(); await page.waitForTimeout(200); await page.keyboard.insertText(name); await page.keyboard.press('Tab');
      await button(page,'Сохранить').click();
      await page.getByText(name,{exact:true}).waitFor();
    }
    async function login(account) {
      const context=await browser.newContext({permissions:textOnly ? [] : ['microphone','camera'],viewport:{width:1280,height:900}});
      await context.addInitScript(()=>{
        const capture=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
        navigator.mediaDevices.getUserMedia=async constraints=>{
          if(!constraints.video || !window.qrCameraImage) return capture(constraints);
          const image=new Image();image.src=window.qrCameraImage;await image.decode();
          const canvas=document.createElement('canvas');canvas.width=canvas.height=512;
          const context=canvas.getContext('2d');
          const draw=()=>{context.fillStyle='white';context.fillRect(0,0,512,512);context.drawImage(image,0,0,512,512);};
          draw();const timer=setInterval(draw,100),stream=canvas.captureStream(10);
          const track=stream.getVideoTracks()[0],stop=track.stop.bind(track);
          track.stop=()=>{clearInterval(timer);context.clearRect(0,0,512,512);image.src='';stop();};
          return stream;
        };
        window.callPeers=[];
        window.RTCPeerConnection=new Proxy(window.RTCPeerConnection,{construct(target,args){
          const connection=Reflect.construct(target,args);
          window.callPeers.push(connection);
          return connection;
        }});
        window.soundPlays=[];
        const play=HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play=function(...args){
          const result=play.apply(this,args);
          if(this.src.includes('/sounds/')) result.then(()=>window.soundPlays.push({src:this.src,audio:this}),()=>{});
          return result;
        };
      });
      const page=await context.newPage(); pages.push(page);
      page.on('console', message=>{
        const text=message.text();
        if(text.includes('onCallHangup') || text.includes('hangup res =>') || text.includes('hangup error =>')) console.log('Call diagnostic:',text.split('=>')[0]);
      });
      await page.goto(webUrl);
      await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
      await fill(page,'Имя пользователя',account.username);
      await fill(page,'Пароль аккаунта',account.password);
      await page.getByText('Параметры подключения',{exact:true}).click();
      await fill(page,'Профиль устройства',account.username);
      await fill(page,'Отдельная локальная фраза (от 12 символов)','independent consent test local phrase');
      await button(page,'Войти').click();
      await button(page,'Найти человека').waitFor({timeout:60000});
      return page;
    }
    const a=await login(alice), b=await login(bob);
    if(process.env.VOICECHAT_LINKS_ONLY==='1') {
      a.setDefaultTimeout(15000);
      console.log('Links: create isolated encrypted room');
      await request(matrixUrl,'/_matrix/client/v3/createRoom',{name:'Ссылки · приёмка',initial_state:[
        {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
      ]},alice.access_token);
      await a.bringToFront();
      await a.getByRole('button',{name:/^Группы(?: \d+)?$/}).click();
      await a.getByRole('button',{name:/^Ссылки · приёмка /}).click();
      await a.setViewportSize({width:390,height:844});
      if(process.env.VOICECHAT_SKIP_LINKS!=='1') await require('./check_link_cards.cjs')({page:a,fill,button,waitForAnnouncement,root});
      console.log('PASS: focused link playback');
      return;
    }
    await button(a,'Найти человека').click();
    await fill(a,'Поиск пользователей',bob.username); await button(a,'Найти').click();
    await a.getByRole('checkbox',{name:`${bob.username} ${bob.user_id}`,exact:true}).click();
    await waitForAnnouncement(a,'Приглашение отправлено. После подтверждения собеседник появится в «Люди».');
    await a.waitForTimeout(350);
    await a.getByRole('button',{name:/Приглашения/}).click();
    await button(a,'Отменить запрос').waitFor({timeout:30000});
    await button(a,'Закрыть').click();
    await b.waitForTimeout(11000);
    await b.getByRole('button',{name:/Приглашения/}).click();
    await button(b,'Принять').waitFor();
    await button(b,'Принять').click();
    await button(b,'Принять').waitFor({state:'hidden',timeout:30000});
    await button(b,'Закрыть').click();
    await a.getByRole('button',{name:new RegExp(bob.username)}).click({timeout:30000});
    await b.getByRole('button',{name:new RegExp(alice.username)}).click({timeout:30000});
    const text='Первое сообщение после согласия';
    await fill(a,'Написать сообщение…',text); await button(a,'Отправить').click();
    await b.getByRole('group',{name:new RegExp(text)}).waitFor({timeout:30000});
    await a.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('sent.wav')));
    await b.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('received.wav')));
    await fill(b,'Написать сообщение…','Ответ с другого устройства'); await button(b,'Отправить').click();
    await button(a,'Действия с сообщением').nth(1).waitFor({timeout:30000});
    await button(a,'Участники и настройки чата').click();
    await a.getByText('Профиль',{exact:true}).waitFor();
    assert.equal(await button(a,'Покинуть чат').count(),0);
    assert.equal(await button(a,'Изменить название').count(),0);
    await button(a,'Закрыть').click();
    if(process.env.VOICECHAT_SCHEDULE_TEST==='1') {
      await require('./check_scheduled_ui.cjs')({a,b,alice,bob,request,fill,button,waitForAnnouncement,root,matrixUrl,apiUrl});
      return;
    }
    if(!textOnly) {
      const escapedBob=bob.user_id.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
      sensitiveVerification=true;
      async function startVerification() {
        await button(a,'Настройки').click();
        await a.getByRole('button',{name:/^Проверить устройства/}).click();
        await a.getByRole('button',{name:new RegExp(escapedBob+' /')}).first().click();
        await button(b,'Открыть').click({timeout:30000});
        await button(b,'Принять проверку').click();
        await button(a,'Совпадают').waitFor({timeout:30000});
        await button(b,'Совпадают').waitFor({timeout:30000});
      }
      await startVerification();
      await button(a,'Не совпадают').click();
      await a.getByText('Коды не совпали. Устройство не подтверждено.',{exact:true}).waitFor();
      await b.getByText('Коды не совпали. Устройство не подтверждено.',{exact:true}).waitFor();
      await button(a,'Закрыть').click(); await button(b,'Закрыть').click();
      await startVerification();
      const codes=async page=>{
        const match=(await page.getByRole('alertdialog').ariaSnapshot()).match(/\d{4}\s+\d{4}\s+\d{4}/);
        assert(match,'SAS must display three numerical codes');
        return match[0].replace(/\s+/g,' ');
      };
      assert((await codes(a))===(await codes(b)),'Independent SAS codes differ');
      await button(a,'Совпадают').click();
      await button(b,'Совпадают').click();
      await a.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000});
      await b.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000});
      await button(a,'Закрыть').click(); await button(b,'Закрыть').click();
      await button(a,'Настройки').click(); await a.getByRole('button',{name:/^Проверить устройства/}).click();
      await a.getByRole('button',{name:/Подтверждено независимой сверкой/}).waitFor();
      await button(a,'Закрыть').click();
      if(process.env.VOICECHAT_QR_TEST==='1') {
        console.log('PASS: two-browser SAS; preparing cross-signing for QR');
        for(const [page,account] of [[a,alice],[b,bob]]) {
          await button(page,'Настройки').click();
          await page.getByRole('button',{name:/^Создать ключ/}).click();
          await fill(page,'Пароль',account.password);await button(page,'Подтвердить').click();
          await button(page,'Я сохранил ключ').click({timeout:30000});
        }
        await button(a,'Настройки').click();await a.getByRole('button',{name:/^Проверить устройства/}).click();
        await a.getByRole('button',{name:new RegExp(escapedBob+' /')}).first().click();
        await button(b,'Открыть').click({timeout:30000});await button(b,'Принять проверку').click();
        await a.waitForTimeout(1000);
        console.log('QR controls:',JSON.stringify({scan:await button(a,'Сканировать QR').count(),sas:await button(a,'Совпадают').count(),label:(await a.locator('body').ariaSnapshot()).includes('QR для текущей проверки устройства')}));
        const code=a.getByText('QR для текущей проверки устройства',{exact:false});
        await code.waitFor();
        const box=await code.boundingBox();assert(box && box.width>100 && box.height>100,'Visible QR required');
        const png=await a.screenshot({clip:box});
        await b.evaluate(data=>window.qrCameraImage=data,'data:image/png;base64,'+png.toString('base64'));
        await button(b,'Сканировать QR').click();
        await a.getByText('Другое устройство сообщает об успешном сканировании.',{exact:false}).waitFor({timeout:30000});
        await button(a,'Вижу успешное сканирование').click();
        for(const page of [a,b]) {
          await page.getByText('Устройство подтверждено',{exact:true}).waitFor({timeout:30000});
          await button(page,'Закрыть').click();
        }
        await b.evaluate(()=>window.qrCameraImage=null);
        console.log('PASS: two-browser standard binary Matrix QR, camera decoding and bilateral confirmation');
      }
      sensitiveVerification=false;
    }
    await createGroup(a,'Согласие на группу',bob);
    await b.getByRole('button',{name:/Приглашения/}).click();
    await b.getByRole('tab',{name:'Группы',exact:true}).click();
    await waitForAnnouncement(b,'Ожидает ответа');
    await button(b,'Принять').click();
    await button(b,'Принять').waitFor({state:'hidden',timeout:30000});
    await waitForAnnouncement(b,'Принято');
    let joined=[];
    for(let i=0;i<30;i++) {
      joined=(await request(matrixUrl,'/_matrix/client/v3/joined_rooms',undefined,bob.access_token)).joined_rooms;
      if(joined.length===2) break;
      await b.waitForTimeout(500);
    }
    assert.equal(joined.length,2,'Group acceptance did not join the room');
    await button(b,'Закрыть').click();
    await a.getByRole('button',{name:/Согласие на группу[\s\S]*Вступили: 2/}).waitFor({timeout:30000});
    assert((await a.locator('body').ariaSnapshot()).includes('вступил'),'Joined member event must appear in group history');
    await createGroup(a,'Отклонённая группа',bob);
    await b.getByRole('button',{name:/Приглашения/}).click();
    await b.getByRole('tab',{name:'Группы',exact:true}).click();
    await button(b,'Отклонить').click();
    await waitForAnnouncement(b,'Отклонено');
    await button(b,'Закрыть').click();
    await b.reload();
    await b.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await button(b,'Найти человека').waitFor({timeout:60000});
    await b.getByRole('button',{name:/Приглашения/}).click();
    await b.getByRole('tab',{name:'Группы',exact:true}).click();
    await waitForAnnouncement(b,'Отклонено');
    await waitForAnnouncement(b,'Принято');
    await button(b,'Закрыть').click();
    assert.equal(await b.evaluate(()=>window.soundPlays.filter(p=>p.src.includes('received.wav')).length),0,'Reloaded history must not replay received sounds');
    await a.getByText('Люди',{exact:true}).click();
    await a.getByRole('button',{name:new RegExp(bob.username)}).getByRole('button',{name:'Действия с чатом',exact:true}).click();
    await a.getByRole('menuitem',{name:'Отключить уведомления',exact:true}).click();
    const receivedBeforeMute=await a.evaluate(()=>window.soundPlays.filter(p=>p.src.includes('received.wav')).length);
    for(const message of ['Тихое сообщение один','Тихое сообщение два']) {
      await fill(b,'Написать сообщение…',message); await button(b,'Отправить').click();
      await b.getByRole('group',{name:new RegExp(message)}).waitFor({timeout:30000});
    }
    const row=a.getByRole('button',{name:new RegExp(bob.username)});
    let label='';
    for(let i=0;i<60;i++) {
      label=await row.getAttribute('aria-label') ?? '';
      if(/\s2$/.test(label)) break;
      await a.waitForTimeout(300);
    }
    assert(/\s2$/.test(label),'Muted room did not keep its unread message count');
    assert.equal(await a.evaluate(()=>window.soundPlays.filter(p=>p.src.includes('received.wav')).length),receivedBeforeMute,'Muted messages must not play received sound');
    await a.getByRole('button',{name:/^Люди\s+1$/}).waitFor();
    await row.click();
    for(let i=0;i<60;i++) {
      label=await row.getAttribute('aria-label') ?? '';
      if(!/\s2$/.test(label)) break;
      await a.waitForTimeout(300);
    }
    assert(!/\s2$/.test(label),'Read receipt did not clear the count');
    if(textOnly) {
      const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
      const people = page => page.getByRole('button',{name:/^Люди(?: \d+)?$/});
      const groups = page => page.getByRole('button',{name:/^Группы(?: \d+)?$/});
      const person = page => page.getByRole('button',{name:new RegExp(bob.username)});
      const group = page => page.getByRole('button',{name:/Согласие на группу /});
      async function assertMute(page,row,muted) {
        let visible;
        for(let i=0;i<100;i++) {
          visible=(await row.getAttribute('aria-label')||'').includes('Уведомления отключены');
          if(visible===muted) break;
          await page.waitForTimeout(100);
        }
        assert.equal(visible,muted,'The mute icon must be included in the accessible chat row');
        await row.getByRole('button',{name:'Действия с чатом',exact:true}).click();
        await page.getByRole('menuitem',{name:muted?'Включить уведомления':'Отключить уведомления',exact:true}).waitFor();
        await page.keyboard.press('Escape');
        await page.mouse.click(10,10);
        await page.getByRole('menuitem').first().waitFor({state:'hidden'});
      }
      async function reload(page) {
        await page.reload();
        await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
        await page.getByRole('button',{name:/^Настройки(?: Настройки)?$/}).or(page.getByRole('textbox',{name:'Написать сообщение…',exact:true})).first().waitFor({timeout:60000});
      }
      async function toggle(page,row,enabled) {
        await row.getByRole('button',{name:'Действия с чатом',exact:true}).click();
        await page.getByRole('menuitem',{name:enabled?'Включить уведомления':'Отключить уведомления',exact:true}).click();
        await page.mouse.move(2,2);
        await assertMute(page,row,!enabled);
      }
      await assertMute(a,person(a),true);
      await reload(a); await people(a).click();
      await assertMute(a,person(a),true);
      await a.screenshot({path:path.join(root,'.prototype/ui/chat-list-muted-person.png')});
      await button(a,'Закрыть чат').click();
      for(const text of ['Непрочитанное личное один','Непрочитанное личное два']) {
        await fill(b,'Написать сообщение…',text); await button(b,'Отправить').click();
        await b.getByRole('group',{name:new RegExp(escape(text))}).waitFor();
      }
      await a.getByRole('button',{name:new RegExp(escape(bob.username)+'[\\s\\S]*\\s2$')}).waitFor();
      await a.getByRole('button',{name:/^Люди 1$/}).waitFor();
      await groups(b).click(); await group(b).click();
      await b.getByText('Согласие на группу',{exact:true}).waitFor();
      for(const text of ['Непрочитанное групповое один','Непрочитанное групповое два']) {
        await fill(b,'Написать сообщение…',text); await button(b,'Отправить').click();
        await b.getByRole('group',{name:new RegExp(escape(text))}).waitFor();
      }
      await a.getByRole('button',{name:/^Группы 1$/}).waitFor();
      await groups(a).click();
      await a.getByRole('button',{name:/^Согласие на группу [\s\S]*\s2$/}).waitFor();
      await toggle(a,group(a),false);
      await reload(a); await groups(a).click();
      await assertMute(a,group(a),true);
      await a.screenshot({path:path.join(root,'.prototype/ui/chat-list-muted-group.png')});
      const second = await login(alice);
      await second.bringToFront();
      await people(second).click(); await person(second).click();
      await second.waitForTimeout(700); await a.bringToFront();
      await a.getByRole('button',{name:/^Люди$/}).waitFor();
      await second.bringToFront();
      await groups(second).click(); await group(second).click();
      await second.waitForTimeout(700); await a.bringToFront();
      await a.getByRole('button',{name:/^Группы$/}).waitFor();
      assert(!/\s2$/.test(await group(a).getAttribute('aria-label')||''),'Reading on another device must clear group unread');
      await toggle(a,group(a),true);
      await people(a).click(); await toggle(a,person(a),true);
      await reload(a); await people(a).click();
      await assertMute(a,person(a),false);
      await groups(a).click(); await assertMute(a,group(a),false);
      await a.screenshot({path:path.join(root,'.prototype/ui/chat-list-text.png')});
      fs.writeFileSync(path.join(root,'prototype/verified-chat-list-run.json'),JSON.stringify({
        date:'2026-10-22',result:'PASS',scope:'text-only web, three isolated contexts',
        muted_person_and_group_icons_persist:true,unmute_persists:true,
        unread_messages_per_room:2,unread_chat_count_per_tab:1,
        reading_on_another_device_clears_counts:true,calls_started:false,microphone_started:false,
      },null,2)+'\n');
      await group(a).click();
      await a.setViewportSize({width:390,height:844});
      if(process.env.VOICECHAT_SKIP_LINKS!=='1') await require('./check_link_cards.cjs')({page:a,fill,button,waitForAnnouncement,root});
      if(process.env.VOICECHAT_TEMPORARY_TEST==='1') {
        await a.getByRole('button',{name:/^Временное сообщение/}).click();
        await a.getByText('Исчезнет через 10 с',{exact:true}).waitFor();
        const apply=await button(a,'Применить').boundingBox();
        assert(apply,'Visible Apply button required');
        await a.mouse.click(apply.x+apply.width/2,apply.y+apply.height/2);
        await a.getByRole('button',{name:/^Временное сообщение · 10 с/}).waitFor();
        const temporaryText='Временный секрет '+Date.now();
        await fill(a,'Написать сообщение…',temporaryText); await button(a,'Отправить').click();
        await waitForAnnouncement(a,temporaryText);
        await waitForAnnouncement(a,'Исчезнет через');
        await a.screenshot({path:path.join(root,'.prototype/ui/temporary-message.png')});
        await b.bringToFront();
        await b.getByRole('group',{name:new RegExp(escape(temporaryText))}).waitFor({timeout:6000});
        await a.bringToFront();
        await a.getByRole('group',{name:new RegExp(escape(temporaryText))}).waitFor({state:'hidden',timeout:13000});
        await b.bringToFront();
        await b.getByRole('group',{name:new RegExp(escape(temporaryText))}).waitFor({state:'hidden',timeout:5000});
        await a.bringToFront(); await reload(a);
        if(await button(a,'Закрыть чат').count()) await button(a,'Закрыть чат').click();
        await groups(a).click(); await group(a).click();
        await a.getByRole('textbox',{name:'Написать сообщение…',exact:true}).waitFor();
        assert.equal(await a.getByRole('group',{name:new RegExp(escape(temporaryText))}).count(),0);
        await fill(a,'Поиск по загруженной истории',temporaryText);
        assert.equal(await a.getByRole('group',{name:new RegExp(escape(temporaryText))}).count(),0);
        fs.writeFileSync(path.join(root,'prototype/verified-temporary-ui-run.json'),JSON.stringify({
          run:Math.floor(Date.now()/1000),result:'PASS',scope:'real E2EE between two web clients; 390px sender',
          temporary_body_decrypted_by_recipient:true,expires_after_ten_seconds:true,
          expired_body_hidden_on_both_clients:true,reload_and_local_search_hide_expired_body:true,
        },null,2)+'\n');
      }
      console.log('PASS: chat list and requested acceptance scenarios; no calls or microphone');
      return;
    }
    await button(a,callButton).click();
    await button(b,'Принять').waitFor({timeout:30000});
    await b.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('ringtone.wav')));
    await button(b,'Принять').click();
    await waitForAnnouncement(a,video ? 'защищённое видео' : 'защищённое аудио');
    await waitForAnnouncement(b,video ? 'защищённое видео' : 'защищённое аудио');
    if(video) {
      await videoFrames(a); await videoFrames(b);
      await toggleCamera(a);
      await videoFrames(a);
      await qualityCheck(a,b);
      if(network) await networkCheck(a,b,'direct');
      await a.screenshot({path:path.join(root,'.prototype/ui/direct-video.png')});
    }
    await b.waitForFunction(()=>window.soundPlays.filter(p=>p.src.includes('ringtone.wav')).every(p=>p.audio.paused));
    await a.waitForFunction(()=>window.soundPlays.filter(p=>p.src.includes('ringback.wav')).every(p=>p.audio.paused));
    await a.waitForTimeout(2200);
    console.log('Checking direct-call termination');
    await button(a,'Завершить').click();
    await button(a,'Закрыть').click();
    await button(b,'Закрыть').click();
    console.log('Checking answered group-call timeout');
    await a.getByText('Группы',{exact:true}).click();
    await a.getByRole('button',{name:/Согласие на группу/}).click();
    await button(a,callButton).click();
    await button(b,'Принять').waitFor({timeout:30000});
    await button(b,'Принять').click();
    await waitForAnnouncement(a,video ? 'Защищённое видео' : 'Защищённое аудио');
    await waitForAnnouncement(b,video ? 'Защищённое видео' : 'Защищённое аудио');
    if(video) {
      await videoFrames(a); await videoFrames(b);
      await toggleCamera(a);
      await videoFrames(a);
      await qualityCheck(a,b);
      if(network) await networkCheck(a,b,'group');
      await a.screenshot({path:path.join(root,'.prototype/ui/group-video.png')});
    }
    await button(b,'Завершить').click();
    await button(b,'Закрыть').click();
    await a.waitForTimeout(46000);
    assert(await button(a,'Завершить').isVisible(),'An answered group call must not time out after another participant leaves');
    await button(a,'Завершить').click();
    await button(a,'Закрыть').click();
    await a.getByText('Люди',{exact:true}).click();
    const c=await login(charlie);
    for(let i=0;i<60;i++) {
      const keys=await request(matrixUrl,'/_matrix/client/v3/keys/query',{device_keys:{[charlie.user_id]:[]}},alice.access_token);
      if(Object.keys(keys.device_keys[charlie.user_id] ?? {}).length) break;
      assert(i<59,'Offline recipient did not publish device keys');
      await c.waitForTimeout(300);
    }
    await c.goto('about:blank');
    await button(a,'Найти человека').click();
    await fill(a,'Поиск пользователей',charlie.username); await button(a,'Найти').click();
    await a.getByRole('checkbox',{name:`${charlie.username} ${charlie.user_id}`,exact:true}).click();
    await a.getByText(charlie.username,{exact:true}).last().waitFor({timeout:30000});
    const offlineText='Сообщение первому офлайн-контакту';
    await fill(a,'Написать сообщение…',offlineText); await button(a,'Отправить').click();
    await a.getByRole('group',{name:new RegExp(offlineText)}).waitFor({timeout:30000});
    const rooms=(await request(matrixUrl,'/_matrix/client/v3/joined_rooms',undefined,alice.access_token)).joined_rooms;
    let offlineRoom;
    for(const id of rooms) {
      const state=await request(matrixUrl,`/_matrix/client/v3/rooms/${encodeURIComponent(id)}/state`,undefined,alice.access_token);
      if(state.some(e=>e.type==='m.room.member' && e.state_key===charlie.user_id && e.content.membership==='invite')) offlineRoom=id;
    }
    assert(offlineRoom,'Recipient must still be invited while offline');
    let wire;
    for(let i=0;i<120;i++) {
      wire=await request(matrixUrl,`/_matrix/client/v3/rooms/${encodeURIComponent(offlineRoom)}/messages?dir=b&limit=10`,undefined,alice.access_token);
      if(wire.chunk.some(e=>e.type==='m.room.encrypted')) break;
      await a.waitForTimeout(500);
    }
    assert(wire.chunk.some(e=>e.type==='m.room.encrypted'),'First offline message must reach encrypted server history');
    assert(!JSON.stringify(wire).includes(offlineText),'Plaintext leaked to server');
    await c.goto(webUrl);
    await c.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await c.getByRole('button',{name:new RegExp(alice.username)}).click({timeout:60000});
    await c.getByRole('group',{name:new RegExp(offlineText)}).waitFor({timeout:60000});
    await c.goto('about:blank');
    const roomPath=`/_matrix/client/v3/rooms/${encodeURIComponent(offlineRoom)}`;
    await request(matrixUrl,`${roomPath}/leave`,{},charlie.access_token);
    await request(matrixUrl,`${roomPath}/invite`,{user_id:charlie.user_id},alice.access_token);
    await request(matrixUrl,`${roomPath}/state/m.room.history_visibility`,{history_visibility:'joined'},alice.access_token,'PUT');
    await a.waitForTimeout(1000);
    const legacyText='Офлайн-доставка после обновления старого диалога';
    await fill(a,'Написать сообщение…',legacyText); await button(a,'Отправить').click();
    let migrated=false;
    for(let i=0;i<120;i++) {
      const state=await request(matrixUrl,`${roomPath}/state/m.room.history_visibility`,undefined,alice.access_token);
      wire=await request(matrixUrl,`${roomPath}/messages?dir=b&limit=15`,undefined,alice.access_token);
      migrated=state.history_visibility==='invited' && wire.chunk.filter(e=>e.type==='m.room.encrypted').length>=2;
      if(migrated) break;
      await a.waitForTimeout(500);
    }
    assert(migrated,'Legacy joined history did not migrate and deliver encrypted offline');
    await c.goto(webUrl);
    await c.locator('flt-semantics-placeholder').evaluate(el=>el.click());
    await c.getByRole('button',{name:new RegExp(alice.username)}).click({timeout:60000});
    await c.getByRole('group',{name:new RegExp(legacyText)}).waitFor({timeout:60000});
    await c.goto('about:blank');
    await button(a,'Голосовой звонок').click();
    await button(a,'Завершить').waitFor({timeout:30000});
    await a.waitForFunction(()=>window.soundPlays.some(p=>p.src.includes('ringback.wav')));
    await a.waitForTimeout(1500);
    assert(await button(a,'Завершить').isVisible(),'Offline outgoing call disappeared');
    await button(a,'Завершить').waitFor({state:'hidden',timeout:55000});
    await a.waitForFunction(()=>window.soundPlays.filter(p=>p.src.includes('ringback.wav')).every(p=>p.audio.paused));
    await button(a,'Закрыть').click();
    fs.mkdirSync(path.join(root,'.prototype/ui'),{recursive:true});
    await a.screenshot({path:path.join(root,'.prototype/ui/contacts.png')});
    console.log('PASS: private consent, two-browser E2EE replies, direct profile/rights, explicit group invitation acceptance, muted unread message/chat counts, read receipts first/legacy offline direct messages and persistent outgoing call window');
  } catch (error) {
    fs.mkdirSync(path.join(root,'.prototype/ui'),{recursive:true});
    if(!sensitiveVerification) {
      for(let i=0;i<pages.length;i++) if(!pages[i].isClosed()) {
        await pages[i].screenshot({path:path.join(root,`.prototype/ui/consent-failure-${i}.png`)});
        if(!await pages[i].getByRole('textbox',{name:'Пароль аккаунта',exact:true}).count()) fs.writeFileSync(path.join(root,`.prototype/ui/consent-accessibility-${i}.txt`),await pages[i].locator('body').ariaSnapshot());
      }
      if(pages[1] && !await pages[1].getByRole('textbox',{name:'Пароль аккаунта',exact:true}).count()) fs.writeFileSync(path.join(root,'.prototype/ui/consent-accessibility.txt'),await pages[1].locator('body').ariaSnapshot());
    }
    throw error;
  } finally {
    if(deadline) clearTimeout(deadline);
    await browser.close();
    if(process.env.VOICECHAT_SCHEDULE_TEST==='1') {
      for(const account of [alice,bob,charlie]) await request(matrixUrl,'/_matrix/client/v3/account/deactivate',{auth:{type:'m.login.password',identifier:{type:'m.id.user',user:account.user_id},password:account.password},erase:true},account.access_token).catch(()=>{});
    }
  }
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
