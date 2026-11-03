import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('../integration_test/call_media_scope.js', import.meta.url), 'utf8');
const {mediaScopeCodecs, mediaScopeSample, singleStreamOutageProof, videoPlayoutSample} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const codecs = [{mimeType:'video/VP8', payloadType:96},
  {mimeType:'video/rtx', payloadType:97, sdpFmtpLine:'apt=96'},
  {mimeType:'video/H264', payloadType:98}];
const reports = () => new Map([
  ['v', {type:'inbound-rtp', kind:'video', codecId:'vc', packetsReceived:200, ssrc:'private'}],
  ['a', {type:'inbound-rtp', kind:'audio', codecId:'ac', packetsReceived:100,
    jitterBufferDelay:2, jitterBufferTargetDelay:3, jitterBufferEmittedCount:50, address:'private'}],
  ['vc', {mimeType:'video/VP8', payloadType:96, secret:'private'}],
  ['ac', {mimeType:'audio/opus', payloadType:111}],
]);
test('scope matches VP8 plus its RTX, excluding audio and unrelated codecs', () => {
  assert.equal(mediaScopeCodecs(reports(), codecs, [96, 97], 'video').valid, true);
  for (const configured of [[96], [96, 97, 98], [96, 97, 111], [96, 96], []])
    assert.equal(mediaScopeCodecs(reports(), codecs, configured, 'video').valid, false);
  const h264 = reports(); h264.get('vc').mimeType = 'video/H264';
  assert.equal(mediaScopeCodecs(h264, codecs, [96, 97], 'video').valid, false);
  assert.equal(JSON.stringify(mediaScopeCodecs(reports(), codecs, [96, 97], 'video')).includes('private'), false);
});
test('snapshots export only bounded counters without identifiers', () => {
  assert.deepEqual(mediaScopeSample(reports(), 'offline', 123), [123, 'offline', 100, 2, 3, 50, 200, null, null, null]);
  const invalid = reports(); invalid.get('a').jitterBufferDelay = Infinity;
  invalid.get('v').packetsReceived = -1;
  assert.deepEqual(mediaScopeSample(invalid, 'private', NaN), [null, null, 100, null, 3, 50, null, null, null, null]);
});
test('outage requires eight measured seconds of stopped video and live audio', () => {
  const rows = Array.from({length:12}, (_, i) => [i * 1000, 'offline', i * 50, 2, 3, i * 50, 200]);
  assert.equal(singleStreamOutageProof(rows, false, 'video').valid, true);
  assert.equal(singleStreamOutageProof(rows.slice(0, 9), false, 'video').valid, false);
  assert.equal(singleStreamOutageProof(rows, true, 'video').valid, false);
  const movingVideo = rows.map((row, i) => [...row.slice(0, 6), 200 + i]);
  assert.equal(singleStreamOutageProof(movingVideo, false, 'video').valid, false);
  assert.equal(singleStreamOutageProof(movingVideo, true, 'video').valid, true);
  for (const value of [0, null]) {
    assert.equal(singleStreamOutageProof(rows.map(row => [...row.slice(0, 2), value, ...row.slice(3)]), false, 'video').valid, false);
  }
});

test('audio scope accepts only Opus and requires stopped audio with live video', () => {
  assert.equal(mediaScopeCodecs(reports(), codecs, [111], 'audio').valid, true);
  for (const configured of [[96, 97], [111, 96], [110], []])
    assert.equal(mediaScopeCodecs(reports(), codecs, configured, 'audio').valid, false);
  const rows = Array.from({length:12}, (_, i) => [i * 1000, 'offline', 100, 2, 3, 50, i * 60]);
  assert.equal(singleStreamOutageProof(rows, false, 'audio').valid, true);
  assert.equal(singleStreamOutageProof(rows, false, 'video').valid, false);
  assert.equal(singleStreamOutageProof(rows, true, 'audio').valid, false);
});

test('video playout records browser timing without RTP identity or media', () => {
  assert.deepEqual(videoPlayoutSample(2, {sourceMs:1000, captureTime:1020, receiveTime:1030,
    displayMs:1100, callbackMs:1090, processingDuration:.003,
    rtpTimestamp:'private', ssrc:'private', body:'private'}), [2, 1000, 1020, 1030, 1100, 1090, 3]);
  assert.deepEqual(videoPlayoutSample(0, {sourceMs:0, captureTime:Infinity, receiveTime:-1,
    displayMs:NaN, processingDuration:'private'}), [0, 0, null, null, null, null, null]);
  for (const id of [-1, 150, 1.5, 'private']) assert.throws(() => videoPlayoutSample(id, {}));
});
