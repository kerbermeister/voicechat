import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';

const source = await fs.readFile(new URL('../integration_test/call_transport_diagnostics.js', import.meta.url), 'utf8');
const {transportDiagnostics} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

test('only allowlisted transport states and counters leave raw RTC stats', async () => {
  const reports = new Map([
    ['secret-transport', {type:'transport', selectedCandidatePairId:'secret-pair'}],
    ['secret-pair', {type:'candidate-pair', state:'succeeded', localCandidateId:'secret-local',
      remoteCandidateId:'secret-remote', bytesSent:10, bytesReceived:20,
      requestsSent:4, requestsReceived:3, responsesSent:3, responsesReceived:4, private:'secret-body'}],
    ['secret-local', {type:'local-candidate', candidateType:'relay', address:'secret-address', url:'secret-url'}],
    ['secret-remote', {type:'remote-candidate', candidateType:'relay'}],
    ['secret-rtp', {type:'outbound-rtp', kind:'video', framesEncoded:12, ssrc:'secret-ssrc'}],
  ]);
  const result = await transportDiagnostics({connectionState:'connected', iceConnectionState:'completed',
    iceGatheringState:'complete', signalingState:'stable', getStats:async () => reports});
  assert.equal(result.connection, 'connected');
  assert.deepEqual(result.selected_pair, {state:'succeeded', local_type:'relay', remote_type:'relay', bytes_sent:10, bytes_received:20});
  assert.deepEqual(result.local_candidates, {host:0, srflx:0, prflx:0, relay:1});
  assert.deepEqual(result.remote_candidates, {host:0, srflx:0, prflx:0, relay:1});
  assert.equal(result.pair_states.succeeded, 1);
  assert.deepEqual(result.pair_checks, {requestsSent:4, requestsReceived:3, responsesSent:3, responsesReceived:4});
  assert.equal(result.encoded_video, 12);
  assert.ok(!JSON.stringify(result).includes('secret'));
});

test('unknown states, addresses as types and non-finite counters are discarded', async () => {
  const result = await transportDiagnostics({connectionState:'secret', getStats:async () => new Map([
    ['transport', {type:'transport', selectedCandidatePairId:'pair'}],
    ['pair', {state:'secret', localCandidateId:'local', bytesSent:Infinity, bytesReceived:-1}],
    ['local', {type:'local-candidate', candidateType:'secret'}],
  ])});
  assert.equal(result.connection, null);
  assert.deepEqual(result.selected_pair, {state:null, local_type:null, remote_type:null, bytes_sent:null, bytes_received:null});
  assert.ok(!JSON.stringify(result).includes('secret'));
});

test('missing peer and rejected stats retain bounded diagnostic evidence', async () => {
  assert.deepEqual(await transportDiagnostics(null), {created:false});
  const result = await transportDiagnostics({connectionState:'failed', iceConnectionState:'failed',
    getStats:async () => { throw Error('secret'); }});
  assert.equal(result.connection, 'failed');
  assert.equal(result.ice, 'failed');
  assert.equal(result.stats_available, false);
  assert.ok(!JSON.stringify(result).includes('secret'));
});
