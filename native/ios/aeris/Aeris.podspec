Pod::Spec.new do |s|
  s.name = 'Aeris'
  s.module_name = 'Aeris'
  s.version = '0.25.0'
  s.summary = 'Shared Native bridge engine with isolated container connections'
  s.homepage = 'https://github.com/zhangguozhong/aeris-sdk'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Aeris'
  s.source = { :git => 'https://github.com/zhangguozhong/aeris-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version = '6.0'
  s.default_subspec = 'Core'
  s.subspec 'Core' do |ss|
    ss.source_files = 'Sources/Core/**/*.swift', 'Sources/Invocation/**/*.{h,m}'
    ss.public_header_files = 'Sources/Invocation/include/*.h'
    ss.dependency 'AerisContracts', '= 0.25.0'
  end
  s.subspec 'Transports' do |ss|
    ss.source_files = 'Sources/Transports/**/*.swift'
    ss.dependency 'Aeris/Core'
  end
  s.subspec 'UIKitContext' do |ss|
    ss.source_files = 'Sources/UIKitContext/**/*.swift'
    ss.frameworks = 'UIKit'
    ss.dependency 'Aeris/Core'
  end
  s.subspec 'SystemEventSources' do |ss|
    ss.source_files = 'Sources/SystemEventSources/**/*.swift'
    ss.frameworks = 'Network', 'UIKit'
    ss.dependency 'Aeris/UIKitContext'
  end
  s.subspec 'WebKitBridge' do |ss|
    ss.source_files = 'Sources/WebKitBridge/**/*.swift'
    ss.frameworks = 'WebKit', 'UIKit'
    ss.dependency 'Aeris/Transports'
    ss.dependency 'Aeris/UIKitContext'
  end
  s.subspec 'UnityBridge' do |ss|
    ss.source_files = 'Sources/UnityBridge/**/*.swift'
    ss.dependency 'Aeris/Transports'
    ss.dependency 'Aeris/UIKitContext'
  end
end
