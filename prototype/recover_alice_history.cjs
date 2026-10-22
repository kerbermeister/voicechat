// The recipient proof must come from Alice's own displayed fingerprint, not keys/query.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {selectors} = require('playwright');
const withRetainedBob = require('./sync_demo_history.cjs');
const root = path.join(__dirname, '..', '.prototype');
const target = JSON.parse(fs.readFileSync(path.join(root, 'alice-history-target.json')));
const audit = JSON.parse(fs.readFileSync(path.join(root, 'alice-history-audit.json')));
const sessions = audit.profiles.find(p => p.role === 'bob').matchingSessions;
assert.equal(target.user, '@alice:voicechat.local');
assert.equal(target.device, 'MUIXORLRKV', 'Only the existing Alice device is authorized');
assert.match(target.fingerprint, /^[A-Za-z0-9+/]{43}$/);
assert.equal(sessions.length, 7, 'Review the transfer scope if the retained sessions change');
selectors.setTestIdAttribute('flt-semantics-identifier');
const statusFile = path.join(root, 'alice-history-transfer.json');
let stage = 'open retained Bob';

withRetainedBob(async page => {
  const approved = new Set();
  let encryptedReplies = 0, roomMessages = 0, verified = false, unsafeReplies = 0;
  const report = phase => fs.writeFileSync(statusFile, JSON.stringify({
    phase, approved: approved.size, expected: sessions.length,
    encryptedReplies, unsafeReplies, roomMessages,
    forwardedSessions: [...approved],
  }), {mode:0o600});
  const isEncryptedReply = response => {
    const request = response.request();
    if (request.method() !== 'PUT' || !/\/sendToDevice\/m\.room\.encrypted\//.test(new URL(request.url()).pathname)) return false;
    return request.postDataJSON()?.messages?.[target.user]?.[target.device]?.algorithm === 'm.olm.v1.curve25519-aes-sha2';
  };
  try {
  const button = name => page.getByRole('button', {name, exact: true});
  stage = 'read Bob own public fingerprint';
  await button('Настройки').click();
  await page.getByRole('button', {name:/^Проверить устройства/}).click();
  await page.getByText('Проверка личности устройств', {exact:true}).waitFor();
  const own = await page.locator('flt-semantics').evaluateAll(nodes =>
    nodes.map(n => n.getAttribute('aria-label') || n.textContent).find(text => text?.includes('Это устройство: @bob:voicechat.local')));
  const proof = own?.match(/Это устройство:\s*(@[^\s]+)\s*\/\s*([^\s]+)\s*Ваш отпечаток:\s*([A-Za-z0-9+/]+)/);
  if (!proof) fs.writeFileSync(path.join(root,'history-proof-aria.txt'), await page.locator('flt-semantics-host').ariaSnapshot(), {mode:0o600});
  assert(proof, 'Bob must display his own local fingerprint');
  fs.writeFileSync(path.join(root, 'bob-history-proof.json'), JSON.stringify({user:proof[1],device:proof[2],fingerprint:proof[3]}), {mode:0o600});
  await button('Закрыть').click();
  await button('Настройки').click();
  stage = 'open pending history requests';
  await page.getByRole('button', {name:/^Запросы истории/}).click();
  await page.getByText('Запросы истории', {exact:true}).waitFor();
  await page.route('**/_matrix/client/v3/sendToDevice/**', route => {
    const request = route.request();
    const content = request.postDataJSON()?.messages?.[target.user]?.[target.device];
    if (content && (JSON.stringify(content).includes('session_key') || new URL(request.url()).pathname.includes('/m.forwarded_room_key/'))) {
      unsafeReplies++;
      return route.abort();
    }
    return route.continue();
  });
  page.on('request', request => {
    const route = new URL(request.url()).pathname;
    if (request.method() !== 'PUT') return;
    if (/\/sendToDevice\/m\.room\.encrypted\//.test(route)) {
      const content = request.postDataJSON()?.messages?.[target.user]?.[target.device];
      if (content) {
        if (content.algorithm !== 'm.olm.v1.curve25519-aes-sha2') unsafeReplies++;
      }
    }
    if (/\/rooms\/[^/]+\/send\//.test(route)) roomMessages++;
  });
  page.on('response', response => {
    if (response.ok() && isEncryptedReply(response)) {
      encryptedReplies++;
      report('encrypted_reply_accepted');
    }
  });
  report('waiting_for_alice');
  stage = 'wait for exact Alice requests';
  const deadline = Date.now() + 10 * 60 * 1000;
  while (approved.size < sessions.length && Date.now() < deadline) {
    for (const {session} of sessions) {
      if (approved.has(session)) continue;
      const card = page.getByTestId('history-key-' + session).first();
      if (!await card.count()) continue;
      assert((await card.ariaSnapshot()).includes(`${target.user} / ${target.device}`), 'Only the exact verified Alice device may receive these keys');
      if (!verified) {
        stage = 'compare Alice own fingerprint';
        await card.getByRole('button', {name:'Сверить отпечаток',exact:true}).click();
        await button('Отмена').click();
        await page.getByText('Сверка отменена. Ключи не переданы.',{exact:true}).waitFor();
        assert.equal(encryptedReplies,0,'Canceling verification must not transfer a key');
        await card.getByRole('button', {name:'Сверить отпечаток',exact:true}).click();
        const input = page.getByRole('textbox', {name:'Полный отпечаток Ed25519',exact:true});
        await input.click(); await page.waitForTimeout(150);
        await page.keyboard.insertText(target.fingerprint);
        await page.waitForTimeout(150); await page.keyboard.press('Tab');
        await button('Сверить').click();
        await page.getByText('Отпечаток совпал. Устройство проверено локально.',{exact:true}).waitFor();
        verified = true;
      }
      stage = 'encrypted history forwarding';
      const reply = page.waitForResponse(isEncryptedReply, {timeout:15000});
      await card.getByRole('button',{name:'Передать ключ',exact:true}).click();
      assert((await reply).ok(), 'The server must accept the encrypted key reply');
      await page.getByText('Ключ истории передан зашифрованным сообщением.',{exact:true}).waitFor();
      approved.add(session);
      report('transferring');
    }
    if (approved.size < sessions.length) await page.waitForTimeout(500);
  }
  assert.equal(approved.size,sessions.length,'Not every retained old session was requested and forwarded');
  assert.equal(encryptedReplies,sessions.length);
  assert.equal(unsafeReplies,0,'A history key must never be sent in plaintext');
  assert.equal(roomMessages,0,'Recovery must not resend or replace the old messages');
  report('forwarded');
  console.log(JSON.stringify({forwarded:approved.size,encryptedReplies,roomMessages}));
  } catch (error) {
    report('failed_at_' + stage.replaceAll(' ', '_'));
    if (stage === 'encrypted history forwarding' || stage === 'compare Alice own fingerprint') {
      fs.writeFileSync(path.join(root,'history-transfer-error-aria.txt'), await page.locator('flt-semantics-host').ariaSnapshot(), {mode:0o600});
    }
    throw error;
  }
}).catch(error => {console.error('History transfer failed at ' + stage + ': ' + error.name);process.exitCode=1;});
