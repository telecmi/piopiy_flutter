Pod::Spec.new do |s|
  s.name             = 'piopiy_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Official PIOPIY voice SDK for Flutter — TeleCMI voice calls with CallKit and push wake-ups.'
  s.description      = <<-DESC
PIOPIY voice SDK for Flutter: voice calls over the TeleCMI network with the
native iOS call UI (CallKit), PushKit wake-ups handled entirely inside the
plugin, and automatic push-token registration.
                       DESC
  s.homepage         = 'https://github.com/telecmi/piopiy_flutter'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'TeleCMI' => 'support@telecmi.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'CallKit', 'PushKit', 'AVFoundation'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
