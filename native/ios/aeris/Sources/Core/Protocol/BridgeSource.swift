import Foundation

/// 稳定的原生来源码，值仅可追加；Cocos 是预留值，尚未实现对应 Transport。
@objc(AerisBridgeSource) public enum BridgeSource: Int {
    case unknown = 0
    case web = 1
    case reactNative = 2
    case flutter = 3
    case unity = 4
    case cocos = 5
}
