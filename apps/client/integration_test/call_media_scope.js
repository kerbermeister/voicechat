// Synthetic lab only. Export selected codec numbers and allowlisted counters;
// stats IDs, SSRC, SDP, addresses and media never leave this module.
const number = value => Number.isFinite(value) && value >= 0 && value <= 1e12 ? value : null;
const inbound = (reports, kind) => [...reports.values()].find(row => row.type === 'inbound-rtp' && row.kind === kind);

export function mediaScopeCodecs(reports, codecs, configured, kind) {
  const video = reports.get(inbound(reports, 'video')?.codecId);
  const audio = reports.get(inbound(reports, 'audio')?.codecId);
  const vp8 = codecs.filter(codec => codec.mimeType?.toLowerCase() === 'video/vp8').map(codec => codec.payloadType);
  const videoTypes = codecs.filter(codec => vp8.includes(codec.payloadType) ||
    (codec.mimeType?.toLowerCase() === 'video/rtx' &&
      vp8.some(payload => new RegExp(`(?:^|;)\\s*apt=${payload}(?:;|$)`).test(codec.sdpFmtpLine ?? ''))))
    .map(codec => codec.payloadType);
  const selected = kind === 'video' ? video : audio;
  const expected = kind === 'video' ? videoTypes : [audio?.payloadType];
  const valid = ['video', 'audio'].includes(kind) && configured.length > 0 && new Set(configured).size === configured.length &&
    configured.every(payload => Number.isInteger(payload) && payload >= 96 && payload <= 127 && expected.includes(payload)) &&
    expected.every(payload => configured.includes(payload)) &&
    video?.mimeType?.toLowerCase() === 'video/vp8' && audio?.mimeType?.toLowerCase() === 'audio/opus' &&
    configured.includes(selected?.payloadType) &&
    (kind === 'video' ? !configured.includes(audio.payloadType) : videoTypes.every(payload => !configured.includes(payload)));
  return {valid, impaired_media:kind, configured_payload_types:[...configured], negotiated_video_payload_types:videoTypes,
    video_payload_type:number(video?.payloadType),
    audio_payload_type:number(audio?.payloadType)};
}

export function mediaScopeSample(reports, phase, time) {
  const audio = inbound(reports, 'audio'), video = inbound(reports, 'video');
  return [number(time), ['clean', 'delay', 'loss', 'offline'].includes(phase) ? phase : null,
    ...['packetsReceived', 'jitterBufferDelay', 'jitterBufferTargetDelay', 'jitterBufferEmittedCount']
      .map(field => number(audio?.[field])), number(video?.packetsReceived),
    ...['jitterBufferDelay', 'jitterBufferTargetDelay', 'jitterBufferEmittedCount'].map(field => number(video?.[field]))];
}

export function singleStreamOutageProof(samples, cleanOnly, kind) {
  // Skip the first second: packets already in flight are not evidence of bypass.
  const offline = samples.filter(row => row[1] === 'offline');
  const first = offline[1], last = offline.at(-1);
  const delta = index => first && last && first[index] !== null && last[index] !== null &&
    last[index] >= first[index] ? last[index] - first[index] : null;
  const audio = delta(2), video = delta(6);
  const live = kind === 'video' ? audio : video, paused = kind === 'video' ? video : audio;
  return {valid:['audio', 'video'].includes(kind) && !!first && last[0] - first[0] >= 8000 &&
    live > 0 && paused !== null && (cleanOnly ? paused > 0 : paused <= 2),
    impaired_media:kind, clean_control:cleanOnly, audio_packets:audio, video_packets:video};
}
