// Real encrypted browser storage and 5 GB streaming export, in an isolated profile.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const {chromium}=require('playwright');
(async()=>{
  const root=path.resolve(__dirname,'../apps/client/web');
  const server=http.createServer((req,res)=>{
    const name=req.url.split('?')[0];
    if(name==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><title>P2P storage test</title>');return;}
    if(!['/vault.js','/files.js','/files-worker.js'].includes(name)){res.writeHead(404).end();return;}
    res.setHeader('Content-Type','application/javascript');res.end(fs.readFileSync(path.join(root,name)));
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  try{
    const context=await browser.newContext({acceptDownloads:true});
    const page=await context.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.addScriptTag({url:'/vault.js'});await page.addScriptTag({url:'/files.js'});
    await page.evaluate(async()=>{
      const name='isolated-p2p-storage-test', id='a'.repeat(32), other='b'.repeat(32);
      await voicechatVault.open(name,'temporary test password');
      const bytes=new Uint8Array(4194304);bytes.fill(42);
      await voicechatVault.writeP2pBlob(name,`p2p/${id}/0/0`,bytes);
      await voicechatVault.writeP2pBlob(name,`p2p/${other}/0/0`,new Uint8Array([13]));
      await voicechatVault.writeBlob(name,'chat-file/0',new Uint8Array([14]));
      const received=await voicechatVault.readP2pBlob(name,`p2p/${id}/0/0`);
      if(received.length!==bytes.length || !received.every(b=>b===42))throw Error('Encrypted block mismatch');
      const request=indexedDB.open(`${name}.blobs`);
      const db=await new Promise((resolve,reject)=>{request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error)});
      const get=db.transaction('chunks').objectStore('chunks').get(`p2p/${id}/0/0`);
      const envelope=await new Promise(resolve=>get.onsuccess=()=>resolve(get.result));
      if(envelope.v!==2 || !(envelope.body instanceof ArrayBuffer) || envelope.body.byteLength!==bytes.length+16)throw Error('P2P block is not bounded binary ciphertext');
      if(await voicechatVault.usage(name)<bytes.length)throw Error('P2P disk usage missing');
      const put=(key,value)=>new Promise((resolve,reject)=>{const txn=db.transaction('chunks','readwrite');txn.objectStore('chunks').put(value,key);txn.oncomplete=resolve;txn.onerror=()=>reject(txn.error)});
      await put(`p2p/${id}/0/1`,envelope);
      let relocated=false;try{await voicechatVault.readP2pBlob(name,`p2p/${id}/0/1`)}catch{relocated=true}
      if(!relocated)throw Error('Relocated encrypted block accepted');
      new Uint8Array(envelope.body)[0]^=1;await put(`p2p/${id}/0/0`,envelope);
      let tampered=false;try{await voicechatVault.readP2pBlob(name,`p2p/${id}/0/0`)}catch{tampered=true}
      if(!tampered)throw Error('Tampered encrypted block accepted');db.close();
      let refused=false;try{await voicechatVault.deleteP2pBlobs(name,'../')}catch{refused=true}
      if(!refused)throw Error('Invalid cleanup identifier accepted');
      await voicechatVault.deleteP2pBlobs(name,id);
      if(await voicechatVault.readP2pBlob(name,`p2p/${id}/0/0`)!==null)throw Error('Cleanup failed');
      if((await voicechatVault.readP2pBlob(name,`p2p/${other}/0/0`))[0]!==13 || (await voicechatVault.readBlob(name,'chat-file/0'))[0]!==14)throw Error('Cleanup removed unrelated data');
      await voicechatVault.close(name);await voicechatVault.erase(name);
    });
    console.log('PASS encrypted 4 MiB block, isolated cleanup and identifier validation');
    for(const size of [0,5000000000]){
      const event=page.waitForEvent('download',{timeout:60000});
      const finish=page.evaluate(size=>{
        window.p2pRead={maximum:0,count:0,total:0};
        return voicechatFiles.download('p2p-export.bin','application/octet-stream',size,async(from,to)=>{
          if(to-from>4194304 || from<0 || to>size || to<from)throw Error('Unbounded export read');
          p2pRead.maximum=Math.max(p2pRead.maximum,to-from);p2pRead.count++;p2pRead.total+=to-from;
          return new Uint8Array(to-from).fill(42);
        });
      },size);finish.catch(()=>{});
      const download=await event;const file=await download.path();await finish;
      assert.equal(fs.statSync(file).size,size);
      if(size){const fd=fs.openSync(file,'r');try{const sample=Buffer.alloc(32);for(const offset of [0,4294967296,size-32]){assert.equal(fs.readSync(fd,sample,0,32,offset),32);assert(sample.every(b=>b===42));}}finally{fs.closeSync(fd)}}
      const reads=await page.evaluate(()=>window.p2pRead);
      assert.equal(reads.total,size);assert(reads.maximum<=4194304);
      console.log(JSON.stringify({exported:size,reads,result:'PASS'}));
      await download.delete();
    }
    await context.close();
  }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
