const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
module.exports=async({a,b,alice,bob,request,fill,button,waitForAnnouncement,root,matrixUrl,apiUrl})=>{
  a.setDefaultTimeout(15000); b.setDefaultTimeout(15000);
  const due=new Date(Date.now()+180000); due.setSeconds(0,0);
  const pdf=Buffer.from('%PDF-1.7\nScheduled encrypted attachment\n');
  const mark='Отложенный PDF '+Date.now(), groupText='Отложенный временный секрет '+Date.now();
  const cancelled='Не публиковать '+Date.now();
  const jobs=async()=> (await request(apiUrl,'/scheduled',null,alice.access_token)).messages;
  const click=async(page,name)=>{
    const box=await button(page,name).boundingBox(); assert(box,`Visible button: ${name}`);
    await page.mouse.click(box.x+box.width/2,box.y+box.height/2);
  };
  async function choose() {
    await button(a,'Отложенные сообщения').click();
    await a.getByRole('menuitem',{name:'Выбрать время отправки',exact:true}).click();
    await button(a,'Время').click();
    const dialog=a.getByRole('dialog').last();
    const fields=dialog.getByRole('textbox');
    fs.writeFileSync(path.join(root,'.prototype/ui/scheduled-time-picker.txt'),await dialog.ariaSnapshot());
    for(const [index,value] of [[0,due.getHours()],[1,due.getMinutes()]]) {
      const field=fields.nth(index); await field.click(); await a.keyboard.press('ControlOrMeta+A');
      await a.keyboard.insertText(String(value).padStart(2,'0')); await a.keyboard.press('Tab');
      assert.equal(await field.inputValue(),String(value).padStart(2,'0'));
    }
    await a.getByRole('button',{name:/^(OK|ОК)$/}).click();
    await click(a,'Применить');
    await button(a,'Запланировать').waitFor();
  }
  async function waitJobs(count) {
    for(let i=0;i<50;i++) { const list=await jobs(); if(list.length===count)return list; await a.waitForTimeout(300); }
    assert.fail('Server did not acknowledge scheduled job');
  }
  console.log('Schedule: encrypted PDF; recover a temporary control API outage');
  await a.bringToFront();
  await a.setViewportSize({width:390,height:844});
  await a.waitForTimeout(500);
  await button(a,'Дополнительные действия').click();
  await button(a,'Прикрепить файл или видео').click();
  const [chooser]=await Promise.all([a.waitForEvent('filechooser'),a.getByRole('menuitem',{name:'Файл',exact:true}).click()]);
  await chooser.setFiles({name:'scheduled.pdf',mimeType:'application/pdf',buffer:pdf});
  await fill(a,'Написать сообщение…',mark);
  await choose();
  await a.route(apiUrl+'/scheduled',route=>route.request().method()==='POST'
    ? route.fulfill({status:503,contentType:'application/json',body:'{"error":"server_unavailable"}',headers:{'Access-Control-Allow-Origin':new URL(a.url()).origin}})
    : route.continue());
  await button(a,'Запланировать').click();
  await waitForAnnouncement(a,'Сообщение сохранено.');
  assert.equal((await jobs()).length,0);
  await a.unroute(apiUrl+'/scheduled');
  const [directJob]=await waitJobs(1);
  assert.equal(directJob.state,'pending'); assert.equal(directJob.due,due.getTime());
  assert.equal((await b.locator('body').ariaSnapshot()).includes(mark),false);
  console.log('Schedule: cancel a second draft through the 390px dialog');
  await fill(a,'Написать сообщение…',cancelled); await choose(); await button(a,'Запланировать').click();
  let list=await waitJobs(2);
  await button(a,'Отложенные сообщения').click();
  await a.getByRole('menuitem',{name:'Запланированные сообщения',exact:true}).click();
  await waitForAnnouncement(a,'Ожидает публикации');
  await a.getByRole('button',{name:/Ожидает публикации/}).first().click();
  await waitForAnnouncement(a,'scheduled.pdf');
  await waitForAnnouncement(a,mark);
  await button(a,'Закрыть просмотр').click();
  await button(a,'Отменить запланированное сообщение').last().click();
  await waitForAnnouncement(a,'Отменено');
  await a.screenshot({path:path.join(root,'.prototype/ui/scheduled-list.png')});
  await button(a,'Закрыть').click();
  list=await jobs(); assert.equal(list.filter(j=>j.state==='cancelled').length,1);
  console.log('Schedule: encrypted group + publication-relative expiry');
  const group=await request(matrixUrl,'/_matrix/client/v3/createRoom',{name:'Расписание · приёмка',invite:[bob.user_id],initial_state:[
    {type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}},
  ]},alice.access_token);
  await request(matrixUrl,'/_matrix/client/v3/join/'+encodeURIComponent(group.room_id),{},bob.access_token);
  if(await button(a,'Закрыть чат').count()) await button(a,'Закрыть чат').click();
  await a.getByRole('button',{name:/^Группы(?: \d+)?$/}).click();
  await a.getByRole('button',{name:/^Расписание · приёмка /}).click();
  await button(a,'Дополнительные действия').click();
  await button(a,'Временное сообщение').click(); await click(a,'Применить');
  await fill(a,'Написать сообщение…',groupText); await choose(); await button(a,'Запланировать').click();
  list=await waitJobs(3); assert.equal(list.filter(j=>j.state==='pending').length,2);
  await a.reload();
  await a.locator('flt-semantics-placeholder').evaluate(el=>el.click()).catch(()=>{});
  await button(a,'Дополнительные действия').click();
  await button(a,'Отложенные сообщения').waitFor({timeout:30000});
  await button(a,'Отложенные сообщения').click();
  await a.getByRole('menuitem',{name:'Запланированные сообщения',exact:true}).click();
  await waitForAnnouncement(a,'Ожидает публикации'); await button(a,'Закрыть').click();
  assert(due.getTime()>Date.now()+5000,'Test setup must finish before publication');
  await a.close();
  await b.bringToFront();
  await b.getByRole('button',{name:/^Группы(?: \d+)?$/}).click();
  await b.getByRole('button',{name:/^Расписание · приёмка /}).click();
  assert(!(await b.locator('body').ariaSnapshot()).includes(groupText));
  console.log('Schedule: sender tab closed; waiting for server publication');
  const until=due.getTime()+15000;
  while(Date.now()<until) {
    if((await b.locator('body').ariaSnapshot()).includes(groupText)) break;
    await b.waitForTimeout(400);
  }
  await waitForAnnouncement(b,groupText);
  await waitForAnnouncement(b,'Исчезнет через');
  assert(Date.now()>=due.getTime(),'No early publication');
  await b.screenshot({path:path.join(root,'.prototype/ui/scheduled-received.png')});
  const sent=await jobs();
  assert.equal(sent.filter(j=>j.state==='sent').length,2);
  const groupJob=sent.find(j=>j.room_id===group.room_id);
  const event=await request(matrixUrl,'/_matrix/client/v3/rooms/'+encodeURIComponent(group.room_id)+'/event/'+encodeURIComponent(groupJob.event_id),null,bob.access_token);
  assert(event.origin_server_ts>=due.getTime());
  assert(event.content['org.matrix.self_destruct_after']>=event.origin_server_ts+10000);
  await b.waitForTimeout(11500);
  assert(!(await b.locator('body').ariaSnapshot()).includes(groupText));
  await b.getByRole('button',{name:/^Люди(?: \d+)?$/}).click();
  await b.getByRole('button',{name:new RegExp(alice.username+' ')}).click();
  await waitForAnnouncement(b,mark);
  assert(!(await b.locator('body').ariaSnapshot()).includes(cancelled));
  await b.evaluate(()=>{window.savedBytes=[];window.showSaveFilePicker=async()=>({createWritable:async()=>({write:async bytes=>window.savedBytes.push(...bytes),close:async()=>{},abort:async()=>{window.savedBytes=[]}})});});
  await button(b,'Сохранить файл').click();
  await b.waitForFunction(()=>window.savedBytes.length>0);
  assert.deepEqual(Buffer.from(await b.evaluate(()=>window.savedBytes)),pdf);
  fs.writeFileSync(path.join(root,'prototype/verified-scheduled-ui-run.json'),JSON.stringify({
    run:Math.floor(Date.now()/1000),result:'PASS',scope:'actual E2EE between isolated web clients; 390px composer',
    private_encrypted_attachment_decrypted:true,scheduled_preview_decrypted_locally:true,group_encrypted_text_decrypted:true,sender_tab_closed:true,
    no_publication_before_due:true,temporary_duration_starts_at_publication:true,expires_after_publication:true,
    cancelled_message_not_published:true,schedule_survives_reload:true,control_api_outage_retried:true,
  },null,2)+'\n');
  console.log('PASS: scheduled private PDF and group E2EE with sender tab closed');
};
