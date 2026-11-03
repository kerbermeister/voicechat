// Synthetic lab only: retain states/counters, never stats IDs, SDP or addresses.
export async function transportDiagnostics(peer) {
  if (!peer) return {created:false};
  const known = (value, options) => options.includes(value) ? value : null;
  const number = value => Number.isFinite(value) && value >= 0 && value <= 1e12 ? value : null;
  const candidate = value => known(value, ['host', 'srflx', 'prflx', 'relay']);
  const result = {
    created:true,
    connection:known(peer.connectionState, ['new', 'connecting', 'connected', 'disconnected', 'failed', 'closed']),
    ice:known(peer.iceConnectionState, ['new', 'checking', 'connected', 'completed', 'disconnected', 'failed', 'closed']),
    gathering:known(peer.iceGatheringState, ['new', 'gathering', 'complete']),
    signaling:known(peer.signalingState, ['stable', 'have-local-offer', 'have-remote-offer', 'have-local-pranswer', 'have-remote-pranswer', 'closed']),
    stats_available:false,
  };
  let timer;
  try {
    const reports = await Promise.race([peer.getStats(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('Diagnostic deadline')), 2000);
    })]);
    const rows = [...reports.values()];
    const transport = rows.find(row => row.type === 'transport' && row.selectedCandidatePairId);
    const pair = reports.get(transport?.selectedCandidatePairId);
    result.stats_available = true;
    result.local_candidates = Object.fromEntries(['host', 'srflx', 'prflx', 'relay'].map(type =>
      [type, rows.filter(row => row.type === 'local-candidate' && row.candidateType === type).length]));
    result.remote_candidates = Object.fromEntries(['host', 'srflx', 'prflx', 'relay'].map(type =>
      [type, rows.filter(row => row.type === 'remote-candidate' && row.candidateType === type).length]));
    const pairs = rows.filter(row => row.type === 'candidate-pair');
    result.pair_states = Object.fromEntries(['frozen', 'waiting', 'in-progress', 'failed', 'succeeded'].map(state =>
      [state, pairs.filter(row => row.state === state).length]));
    result.pair_checks = Object.fromEntries(['requestsSent', 'requestsReceived', 'responsesSent', 'responsesReceived'].map(field => {
      const values = pairs.map(row => number(row[field]));
      return [field, values.length && values.every(value => value !== null) ? number(values.reduce((a, b) => a + b, 0)) : null];
    }));
    result.selected_pair = pair ? {
      state:known(pair.state, ['frozen', 'waiting', 'in-progress', 'failed', 'succeeded']),
      local_type:candidate(reports.get(pair.localCandidateId)?.candidateType),
      remote_type:candidate(reports.get(pair.remoteCandidateId)?.candidateType),
      bytes_sent:number(pair.bytesSent), bytes_received:number(pair.bytesReceived),
    } : null;
    for (const [label, type, field] of [['encoded_video', 'outbound-rtp', 'framesEncoded'],
      ['decoded_video', 'inbound-rtp', 'framesDecoded']]) {
      const values = rows.filter(row => row.type === type && row.kind === 'video').map(row => number(row[field]));
      result[label] = values.length && values.every(value => value !== null) ? number(values.reduce((a, b) => a + b, 0)) : null;
    }
  } catch (_) { /* States remain useful when getStats fails or never completes. */ }
  finally { clearTimeout(timer); }
  return result;
}
