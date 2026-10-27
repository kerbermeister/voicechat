// Local fixture only: real native Flutter WebRTC <-> Chrome Flutter WebRTC.
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const http=require('node:http');const crypto=require('node:crypto');const {spawn}=require('node:child_process');
const {chromium}=require('playwright');
(async()=>{
 const root=path.resolve(__dirname,'..'),web=path.join(root,'.prototype/p2p-lab-web');
 const sizes=[4194321,0,1,2,3,4,5,6,7,8];
 const files=sizes.map((size,i)=>({name:`файл-${i}.bin`,mime:'application/octet-stream',size,sha256:crypto.createHash('sha256').update(Buffer.alloc(size,42)).digest('hex')}));
 const secret=fs.readFileSync(path.join(root,'.prototype/turnserver.conf'),'utf8').match(/^static-auth-secret=(.+)$/m)[1];
 const username=`${Math.floor(Date.now()/1000)+3600}:p2p-cross`;
 const ice=[{urls:[`turn:127.0.0.1:${process.env.P2P_TURN_PORT||3478}?transport=tcp`],username,credential:crypto.createHmac('sha1',secret).update(username).digest('base64')}];
 const queues=[{native:[],web:[]},{native:[],web:[]}],completed=[{},{}];
 const server=http.createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost');res.setHeader('Cache-Control','no-store');
  if(url.pathname.startsWith('/cross/')){
   const [, ,n,side,done]=url.pathname.split('/');const index=Number(n);
   res.setHeader('Content-Type','application/json');
   if(![0,1].includes(index)){res.writeHead(400).end('{}');return;}
   if(side==='config'){res.end(JSON.stringify({files,ice}));return;}
   if(!['web','native'].includes(side)){res.writeHead(400).end('{}');return;}
   if(req.method==='POST'){
    let body='';for await(const part of req){body+=part;if(body.length>100000){res.writeHead(413).end();return;}}
    const data=JSON.parse(body);
    if(done==='done')completed[index][side]=data;else queues[index][side==='web'?'native':'web'].push(data);
    res.end('{}');return;
   }
   res.end(JSON.stringify({messages:queues[index][side].splice(0)}));return;
  }
  const file=path.resolve(web,'.'+(url.pathname==='/'?'/index.html':url.pathname));
  if(!file.startsWith(web+'/')){res.writeHead(403).end();return;}
  try{res.setHeader('Content-Type',({'.js':'application/javascript','.wasm':'application/wasm','.html':'text/html','.json':'application/json','.ttf':'font/ttf'})[path.extname(file)]||'application/octet-stream');res.end(fs.readFileSync(file));}catch{res.writeHead(404).end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const origin=`http://127.0.0.1:${server.address().port}`;
 const log=fs.openSync('/tmp/voicechat-p2p-cross-native.log','w');
 const native=spawn(path.join(root,'.prototype/tools/flutter/bin/flutter'),['test','integration_test/p2p_cross_test.dart','-d','macos',`--dart-define=P2P_CROSS_URL=${origin}`],{cwd:path.join(root,'apps/client'),env:{...process.env,PATH:path.join(root,'.prototype/cargo/bin')+':'+process.env.PATH,CARGO_HOME:path.join(root,'.prototype/cargo'),RUSTUP_HOME:path.join(root,'.prototype/rustup'),CARGO_PROFILE_DEV_DEBUG:'0',LANG:'en_US.UTF-8',LC_ALL:'en_US.UTF-8',LC_CTYPE:'en_US.UTF-8'},stdio:['ignore',log,log]});
 const exited=new Promise((resolve,reject)=>{native.on('exit',code=>resolve(code));native.on('error',reject)});exited.catch(()=>{});
 const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 try{
  for(let i=0;i<2;i++){
   const page=await browser.newPage();await page.goto(`${origin}/?cross=${i}`);
   await page.getByRole('button',{name:'Run',exact:true}).click({timeout:60000});
   await page.getByText(/^(PASS|FAIL:)/).first().waitFor({timeout:240000});
   assert.equal(await page.getByText(/^(PASS|FAIL:)/).first().innerText(),'PASS');await page.close();
  }
  assert.equal(await exited,0,fs.readFileSync('/tmp/voicechat-p2p-cross-native.log','utf8'));
  for(const session of completed)for(const side of ['web','native']){assert.equal(session[side].passed,true);assert.equal(session[side].files,10);}
  fs.writeFileSync(path.join(root,'.prototype/p2p-evidence/cross.json'),JSON.stringify(completed,null,2)+'\n');console.log(JSON.stringify({result:'PASS',sessions:completed}));
 }finally{if(native.exitCode===null)native.kill('SIGTERM');await browser.close();fs.closeSync(log);await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e.message);process.exitCode=1});
