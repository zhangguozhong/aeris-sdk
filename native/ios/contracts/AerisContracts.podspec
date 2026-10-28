Pod::Spec.new do |s|
  s.name = 'AerisContracts'
  s.module_name = 'AerisContracts'
  s.version = '0.25.0'
  s.summary = 'Minimal Foundation message ingress contracts for Aeris platform plugins'
  s.homepage = 'https://github.com/zhangguozhong/aeris-sdk'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Aeris'
  s.source = { :git => 'https://github.com/zhangguozhong/aeris-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.source_files = 'Sources/**/*.{h,m}'
  s.public_header_files = 'Sources/*.h'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
