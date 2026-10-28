Pod::Spec.new do |s|
  s.name = 'AerisHost'
  s.module_name = 'AerisHost'
  s.version = '0.25.0'
  s.summary = 'Container-scoped native host integration for Aeris'
  s.homepage = 'https://github.com/zhangguozhong/aeris-sdk'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Aeris'
  s.source = { :git => 'https://github.com/zhangguozhong/aeris-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version = '6.0'
  s.default_subspec = 'Common'

  s.subspec 'Common' do |ss|
    ss.source_files = 'Sources/Common/**/*.swift'
    ss.dependency 'Aeris/Transports', '= 0.25.0'
  end
  s.subspec 'ReactNative' do |ss|
    ss.source_files = 'Sources/ReactNative/**/*.swift'
    ss.dependency 'AerisHost/Common'
    ss.dependency 'Aeris/UIKitContext', '= 0.25.0'
    ss.dependency 'AerisRN', '= 0.25.0'
  end
  s.subspec 'Flutter' do |ss|
    ss.source_files = 'Sources/Flutter/**/*.swift'
    ss.dependency 'AerisHost/Common'
    ss.dependency 'Aeris/UIKitContext', '= 0.25.0'
    ss.dependency 'aeris_flutter', '= 0.25.0'
  end
  s.subspec 'Web' do |ss|
    ss.source_files = 'Sources/Web/**/*.swift'
    ss.dependency 'AerisHost/Common'
    ss.dependency 'Aeris/WebKitBridge', '= 0.25.0'
  end
  s.subspec 'Unity' do |ss|
    ss.source_files = 'Sources/Unity/**/*.swift'
    ss.dependency 'AerisHost/Common'
    ss.dependency 'Aeris/UnityBridge', '= 0.25.0'
  end
end
