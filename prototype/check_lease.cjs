// One signaling-only browser; isolated authorizer, real local Matrix and SFU.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {once} = require('node:events');
const readline = require('node:readline');
const {chromium} = require('playwright');
const root = path.join(__dirname, '..');
const scratch = fs.mkdtempSync(path.join(root, '.prototype/lease-check-'));
fs.chmodSync(scratch, 0o700);
const outage = path.join(scratch, 'outage');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function request(base, route, body, token) {
  const response = await fetch(base + route, {
    method: body ? 'POST' : 'GET',
    headers: {'Content-Type':'application/json', ...(token ? {Authorization:'Bearer '+token} : {})},
    ...(body ? {body:JSON.stringify(body)} : {}),
  });
  return {status:response.status, data:await response.json()};
}

(async () => {
  let browser;
  const service = spawn('python3', ['-u', '-c', `
import pathlib, sys, urllib.error
import token_server as server
from call_control import CallStore
root = pathlib.Path(sys.argv[1])
server.CallStore = lambda _, media: CallStore(root / 'calls.sqlite', media)
original = server.Handler.matrix
def matrix(self, *args):
    if (root / 'outage').exists():
        raise urllib.error.URLError('injected Matrix outage')
    return original(self, *args)
server.Handler.matrix = matrix
http = server.ControlServer(('127.0.0.1', 0), server.Handler)
print(http.server_port, flush=True)
http.serve_forever()
`, scratch], {cwd:__dirname, stdio:['ignore','pipe','inherit']});
  try {
    const lines = readline.createInterface({input:service.stdout});
    const [line] = await Promise.race([
      once(lines, 'line'),
      once(service, 'exit').then(() => {throw new Error('Authorizer exited before readiness');}),
      delay(10000).then(() => {throw new Error('Authorizer readiness timeout');}),
    ]);
    assert.match(line, /^\d+$/);
    const api = 'http://127.0.0.1:'+line;
    const matrix = 'http://localhost:8008';
    const username = 'lease_probe_'+Date.now();
    const password = crypto.randomBytes(24).toString('base64url');
    const route = '/_synapse/admin/v1/register';
    const {data:{nonce}} = await request(matrix, route);
    const secret = JSON.parse(fs.readFileSync(path.join(root, '.prototype/secrets.json'))).registration;
    const mac = crypto.createHmac('sha1', secret).update([nonce,username,password,'notadmin'].join('\0')).digest('hex');
    assert.equal((await request(matrix, route, {nonce,username,password,admin:false,mac})).status, 200);
    const {status, data:login} = await request(matrix, '/_matrix/client/v3/login', {type:'m.login.password',user:username,password});
    assert.equal(status, 200);
    const mx = async (route, body) => {
      const response = await request(matrix, '/_matrix/client/v3/'+route, body, login.access_token);
      assert.equal(response.status, 200, route);
      return response.data;
    };
    const ed = crypto.generateKeyPairSync('ed25519');
    const curve = crypto.generateKeyPairSync('x25519');
    const publicKey = key => Buffer.from(key.export({format:'jwk'}).x, 'base64url').toString('base64').replace(/=+$/, '');
    const device = {algorithms:['m.olm.v1.curve25519-aes-sha2','m.megolm.v1.aes-sha2'],
      device_id:login.device_id, keys:{['curve25519:'+login.device_id]:publicKey(curve.publicKey),
        ['ed25519:'+login.device_id]:publicKey(ed.publicKey)}, user_id:login.user_id};
    const canonical = Buffer.from(JSON.stringify(device));
    const signature = crypto.sign(null, canonical, ed.privateKey);
    assert(crypto.verify(null, canonical, ed.publicKey, signature));
    device.signatures = {[login.user_id]:{['ed25519:'+login.device_id]:signature.toString('base64').replace(/=+$/, '')}};
    await mx('keys/upload', {device_keys:device});
    const {room_id} = await mx('createRoom', {initial_state:[{type:'m.room.encryption',state_key:'',content:{algorithm:'m.megolm.v1.aes-sha2'}}]});
    browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
    const page = await browser.newPage();
    await page.addInitScript(() => {
      window.mediaRequests = 0;
      navigator.mediaDevices.getUserMedia = async () => {
        window.mediaRequests++;
        throw new Error('Media capture is forbidden in this signaling test');
      };
    });
    async function connect(token) {
      await page.goto('http://localhost:7358/');
      await page.waitForFunction(() => document.documentElement.dataset.rawReady === 'true');
      await page.evaluate(token => window.postMessage({type:'voicechat.raw',token}, location.origin), token);
    }
    const measurements = [];
    for (const fault of ['no-renewal','matrix-outage']) {
      const body = {room_id,session:crypto.randomBytes(16).toString('hex'),video:false,protocol_version:1};
      let grant;
      for (let attempt=0; attempt<20; attempt++) {
        const response = await request(api, '/token', body, login.access_token);
        if (response.status === 200) {grant=response.data; break;}
        assert.equal(response.data.error, 'generation_settling');
        await delay(200);
      }
      assert(grant, 'Admission did not settle');
      const started = Date.now();
      await connect(grant.token);
      await page.waitForFunction(() => document.documentElement.dataset.rawState === 'connected');
      if (fault === 'matrix-outage') {
        fs.writeFileSync(outage, '1', {mode:0o600});
        const response = await request(api, '/token', {...body,lease_id:grant.lease_id}, login.access_token);
        assert.equal(response.status, 503);
        assert.equal(response.data.error, 'upstream_unavailable');
      }
      await page.waitForFunction(() => document.documentElement.dataset.rawState === 'disconnected', null, {timeout:40000});
      const elapsed = Date.now()-started;
      assert(elapsed >= 25000 && elapsed < 38000, 'Lease expiry deadline violated');
      const claims = JSON.parse(Buffer.from(grant.token.split('.')[1], 'base64url'));
      assert(claims.exp > Date.now()/1000, 'Replay test must run before JWT expiry');
      assert.equal(await page.evaluate(() => window.mediaRequests), 0);
      await connect(grant.token);
      await page.waitForFunction(() => document.documentElement.dataset.rawState === 'rejected');
      measurements.push({fault,disconnect_ms:elapsed,unexpired_replay_rejected:true,media_capture_requests:0});
      fs.rmSync(outage, {force:true});
    }
    await mx('account/deactivate', {auth:{type:'m.login.password',identifier:{type:'m.id.user',user:username},password},erase:true});
    fs.writeFileSync(path.join(__dirname, 'verified-lease-run.json'), JSON.stringify({run:Math.floor(Date.now()/1000),result:'PASS',
      scope:'real SFU signaling and lease expiry; Matrix outage injected at isolated authorizer boundary; no media decryption claim',measurements}, null, 2)+'\n');
    console.log('PASS: real SFU evicts expired leases and rejects unexpired replay during normal operation and Matrix outage');
  } finally {
    await browser?.close();
    service.kill('SIGTERM');
    await once(service, 'exit');
    fs.rmSync(scratch, {recursive:true,force:true});
  }
})().catch(error => {console.error(error.message); process.exitCode=1;});
