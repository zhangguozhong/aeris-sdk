require "json"
package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name = "AerisRN"
  s.module_name = "AerisRN"
  s.version = package["version"]
  s.summary = "Fixed RN send/onMessage channel with host-injected receiver"
  s.homepage = "https://github.com/zhangguozhong/aeris-sdk"
  s.license = { :type => "MIT", :file => "LICENSE" }
  s.author = "Aeris"
  # RN 插件由 npm 包自动链接；固定源码元数据，避免安装路径改变 Pod 锁摘要。
  s.source = { :git => "https://github.com/zhangguozhong/aeris-sdk.git", :tag => s.version.to_s }
  s.platforms = { :ios => min_ios_version_supported }
  s.source_files = "ios/**/*.{h,mm}"
  s.public_header_files = "ios/AerisRNModuleBinding.h", "ios/UBRNModuleBinding.h"
  s.private_header_files = "ios/RCTUnifiedBridge.h"
  s.dependency "AerisContracts", "= 0.25.0"
  install_modules_dependencies(s)
end
