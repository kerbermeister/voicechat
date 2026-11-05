"""Exercise the exact fixture reader on real mono/interleaved Apple buffers."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'AVFoundation requires macOS')
class NativeAudioSamplesTest(unittest.TestCase):
    def test_frame_length_and_channel_stride(self):
        fixture = Path(__file__).resolve().parents[1] / 'integration_test/native_av_marker.swift'
        source = fixture.read_text()
        start = source.index('func nativeMarkerAudioSamples(')
        opening = source.index('{', start)
        depth = 1
        end = opening + 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        reader = source[start:end]
        assertions = r'''
func check(_ common: AVAudioCommonFormat, _ channels: AVAudioChannelCount, _ interleaved: Bool) {
  let format = AVAudioFormat(commonFormat: common, sampleRate: 48000,
                            channels: channels, interleaved: interleaved)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
  buffer.frameLength = 4
  for channel in 0..<Int(channels) {
    let pointer = interleaved ? 0 : channel
    let offset = interleaved ? channel : 0
    for frame in 0..<8 {
      // Opposite channels and excess capacity must never leak into channel 0.
      let value = frame < 4 && channel == 0 ? (frame + 1) * 100 : -2000
      if let shorts = buffer.int16ChannelData {
        shorts[pointer][frame * buffer.stride + offset] = Int16(value)
      } else if let floats = buffer.floatChannelData {
        floats[pointer][frame * buffer.stride + offset] = Float(value) / 32768
      }
    }
  }
  let samples = nativeMarkerAudioSamples(buffer)!
  precondition(samples.count == 4)
  for i in 0..<4 { precondition(samples[i] == Float((i + 1) * 100) / 32768) }
}
check(.pcmFormatInt16, 1, false)
check(.pcmFormatInt16, 2, true)
check(.pcmFormatInt16, 2, false)
check(.pcmFormatFloat32, 2, true)
check(.pcmFormatFloat32, 2, false)
let unsupported = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(
  commonFormat: .pcmFormatFloat64, sampleRate: 48000, channels: 1, interleaved: false)!, frameCapacity: 4)!
unsupported.frameLength = 4
precondition(nativeMarkerAudioSamples(unsupported) == nil)
'''
        with tempfile.TemporaryDirectory(prefix='voicechat-native-pcm-') as directory:
            root = Path(directory)
            script = root / 'check.swift'
            script.write_text('import AVFoundation\n' + reader + '\n' + assertions)
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', root / 'module-cache',
                            script, '-o', root / 'check'], check=True,
                           capture_output=True, text=True, timeout=60)
            subprocess.run([root / 'check'], check=True, capture_output=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
