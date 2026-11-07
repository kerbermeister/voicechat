require 'json'

manifest = JSON.parse(File.read(File.expand_path('../../infra/webrtc-sdk-artifacts.json', __dir__)))
artifact = manifest.fetch('artifacts').fetch('macos')

Pod::Spec.new do |s|
  s.name = 'WebRTC-SDK'
  s.version = manifest.fetch('sdk_version')
  s.summary = 'WebRTC SDK with bounded audio/video synchronization.'
  s.homepage = 'https://github.com/kerbermeister/voicechat'
  s.license = { :type => 'BSD', :file => 'WebRTC.xcframework/LICENSE' }
  s.author = 'webrtc-sdk'
  s.source = { :http => artifact.fetch('url'), :sha256 => artifact.fetch('sha256') }
  s.osx.deployment_target = '10.15'
  s.vendored_frameworks = 'WebRTC.xcframework'
end
