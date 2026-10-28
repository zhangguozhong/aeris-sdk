#if canImport(UIKit)
    import UIKit

    extension BridgeUIContext {
        public convenience init(containerViewController: UIViewController) {
            self.init(container: containerViewController)
        }
        public var containerViewController: UIViewController? { container as? UIViewController }

        /// 仅在原始容器绑定内解析，不查询全局 keyWindow 或 topViewController。
        public func cameraPresenter() throws -> UIViewController {
            guard isValid, let vc = containerViewController, vc.viewIfLoaded?.window != nil,
                !vc.isBeingDismissed, !vc.isMovingFromParent
            else {
                throw BridgeFailure("UI_UNAVAILABLE", "Calling view controller is not attached")
            }
            if let nav = vc.navigationController, nav.visibleViewController !== vc {
                throw BridgeFailure("UI_UNAVAILABLE", "Calling page is no longer visible")
            }
            var ancestor: UIViewController? = vc
            while let node = ancestor {
                guard node.presentedViewController == nil, !node.isBeingDismissed else {
                    throw BridgeFailure("BUSY", "Calling container is already presenting a page")
                }
                ancestor = node.parent
            }
            return vc
        }
    }

#endif
