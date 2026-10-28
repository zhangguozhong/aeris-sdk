import Foundation

/// 仅供原生使用的容器或页面绑定标识，不从协议字段赋值。
/// 目标不可替换，不同页面必须绑定新的上下文。
@MainActor public final class BridgeUIContext {
    public private(set) weak var container: AnyObject?
    private var invalidated = false
    private var observers: [UUID: () -> Void] = [:]
    public var isValid: Bool { !invalidated && container != nil }
    public init(container: AnyObject) { self.container = container }
    @discardableResult public func observeInvalidation(_ action: @escaping () -> Void) -> UUID? {
        guard isValid else {
            action()
            return nil
        }
        let token = UUID()
        observers[token] = action
        return token
    }
    public func removeInvalidationObserver(_ token: UUID?) {
        if let token { observers.removeValue(forKey: token) }
    }
    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        container = nil
        let actions = Array(observers.values)
        observers.removeAll()
        for action in actions { action() }
    }
}
