Pod::Spec.new do |s|
  s.name = 'aeris_flutter'
  s.version = '0.25.0'
  s.summary = 'Fixed Flutter String channel with host-injected Native receiver'
  s.homepage = 'https://docs.flutter.dev/add-to-app'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = 'Aeris'
  # 插件本地自动链接时忽略 source；源码交付仍固定到公开版本。
  s.source = { :git => 'https://github.com/zhangguozhong/aeris-sdk.git', :tag => s.version.to_s }
  s.source_files = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/*.h'
  s.ios.deployment_target = '15.0'
  s.dependency 'Flutter'
  s.dependency 'AerisContracts', '= 0.25.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
