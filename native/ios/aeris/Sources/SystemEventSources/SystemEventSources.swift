#if canImport(UIKit) && canImport(Network)
    import UIKit
    import Network

    @MainActor private final class EventLifetime { var active = true }
    private struct NetworkSnapshot: Sendable {
        let status: String, interface: String
        let connected: Bool, expensive: Bool, constrained: Bool
        init(_ path: NWPath) {
            switch path.status {
            case .satisfied: status = "satisfied"
            case .unsatisfied: status = "unsatisfied"
            case .requiresConnection: status = "requiresConnection"
            @unknown default: status = "unknown"
            }
            connected = path.status == .satisfied
            interface =
                !connected
                ? "none"
                : path.usesInterfaceType(.wifi)
                    ? "wifi"
                    : path.usesInterfaceType(.cellular)
                        ? "cellular" : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            expensive = path.isExpensive
            constrained = path.isConstrained
        }
        var data: [String: Any] {
            [
                "status": status, "connected": connected, "interface": interface,
                "expensive": expensive, "constrained": constrained,
            ]
        }
    }

    /// 仅监听并归一化数据，注入的 emit 回调统一进入 BridgeEngine.publish。
    /// Engine 的每个 topic 分组只有一个监听，由所有订阅容器的连接共享。
    @MainActor public final class NetworkStatusEventProvider: BridgeEventProvider {
        private var current: [String: Any] = [
            "status": "unknown", "connected": false, "interface": "none", "expensive": false,
            "constrained": false,
        ]
        public init() {}
        public func observe(
            context: BridgeUIContext?, emit: @escaping @MainActor ([String: Any]) -> Void
        ) throws -> BridgeEventObservation {
            let monitor = NWPathMonitor()
            let life = EventLifetime()
            monitor.pathUpdateHandler = { [weak self, weak life] path in
                let snapshot = NetworkSnapshot(path)
                Task { @MainActor [weak self, weak life] in
                    guard let self, life?.active == true else { return }
                    self.current = snapshot.data
                    emit(self.current)  // 由 Engine 注入的发布入口。
                }
            }
            monitor.start(queue: DispatchQueue(label: "UnifiedBridge.NetworkMonitor"))
            return BridgeEventObservation(initial: current) {
                life.active = false
                monitor.pathUpdateHandler = nil
                monitor.cancel()
            }
        }
    }

    @MainActor private final class AppearanceObservationView: UIView {
        private var emit: (@MainActor ([String: Any]) -> Void)?
        init(emit: @escaping @MainActor ([String: Any]) -> Void) {
            self.emit = emit
            super.init(frame: .zero)
            isHidden = true
            isUserInteractionEnabled = false
            if #available(iOS 17.0, *) {
                registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                    (view: AppearanceObservationView, _: UITraitCollection) in view.changed()
                }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { changed() }
        }
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            if #unavailable(iOS 17.0) { changed() }
        }
        private func changed() { emit?(Self.snapshot(traitCollection)) }
        func stop() {
            emit = nil
            removeFromSuperview()
        }
        static func snapshot(_ traits: UITraitCollection) -> [String: Any] {
            let style =
                traits.userInterfaceStyle == .dark
                ? "dark" : traits.userInterfaceStyle == .light ? "light" : "unspecified"
            return ["style": style]
        }
    }

    /// 观察原始容器的外观特征，注入的 emit 回调通过 Engine 发布。
    @MainActor public final class AppearanceEventProvider: BridgeEventProvider {
        public init() {}
        public func observe(
            context: BridgeUIContext?, emit: @escaping @MainActor ([String: Any]) -> Void
        ) throws -> BridgeEventObservation {
            guard context?.isValid == true, let controller = context?.containerViewController,
                let root = controller.viewIfLoaded
            else {
                throw BridgeFailure(
                    "UI_UNAVAILABLE", "Calling appearance container has no loaded view")
            }
            let view = AppearanceObservationView(emit: emit)
            root.addSubview(view)
            return BridgeEventObservation(
                initial: AppearanceObservationView.snapshot(controller.traitCollection)
            ) { view.stop() }
        }
    }

    extension BridgeEngine {
        /// 在原生 App 启动时调用一次，与普通模块一起注册。
        public func installSystemEventProviders() throws {
            try registerEventProvider(
                topic: "network.changed", provider: NetworkStatusEventProvider(), delivery: .latest)
            try registerEventProvider(
                topic: "appearance.changed", provider: AppearanceEventProvider(), scope: .uiContext,
                delivery: .latest)
        }
    }
#endif
