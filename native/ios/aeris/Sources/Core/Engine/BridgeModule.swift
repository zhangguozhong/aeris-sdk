import AerisContracts
import Foundation

#if SWIFT_PACKAGE
    import AerisInvocation
#endif

public typealias BridgeCompletion = @MainActor (Result<[String: Any], BridgeFailure>) -> Void

/// 仅注册模块对象，内部自动发现符合要求的 @objc 函数。
@MainActor public protocol BridgeModule: AnyObject {
    var moduleName: String { get }
    var requiredPermissions: Set<String> { get }
}
public extension BridgeModule { var requiredPermissions: Set<String> { [] } }
@MainActor struct ResolvedBridgeInvocation {
    let target: NSObject
    let selector: Selector
    let permissions: Set<String>
    func invoke(_ session: BridgeSession) {
        if !AerisBridgeInvocation.invoke(target, selector: selector, session: session) {
            session.fail("INTERNAL_ERROR", message: "Bridge method invocation failed")
        }
    }
}
