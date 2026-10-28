import AerisContracts
import Foundation

#if SWIFT_PACKAGE
    import AerisInvocation
#endif

@MainActor final class BridgeRegistry {
    private struct Module {
        let target: NSObject
        let permissions: Set<String>
    }
    private var modules: [String: Module] = [:]
    private var cache: [String: ResolvedBridgeInvocation] = [:]
    private(set) var revision = 0
    private(set) var defaultModuleName = DefaultBridge.name
    private func valid(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil
            && !["constructor", "prototype", "__proto__"].contains(name)
    }
    func configureDefaultModule(_ name: String) throws {
        guard valid(name), name != "bridge" else {
            throw BridgeFailure("INVALID_MODULE", "Expected a non-reserved module name")
        }
        defaultModuleName = name
    }
    func register(_ module: any BridgeModule) throws {
        let name = module.moduleName
        guard valid(name), name != "bridge", let target = module as? NSObject else {
            throw BridgeFailure("INVALID_MODULE", "Expected a named NSObject BridgeModule")
        }
        guard modules[name] == nil else { throw BridgeFailure("DUPLICATE_MODULE", name) }
        modules[name] = Module(target: target, permissions: module.requiredPermissions)
        revision += 1
    }
    func resolve(_ raw: String) throws -> (String, ResolvedBridgeInvocation) {
        let names = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(names.count), names.allSatisfy(valid), let methodName = names.last
        else { throw BridgeFailure("INVALID_METHOD", "Invalid method name") }
        let moduleName = names.count == 1 ? defaultModuleName : names[0]
        let canonical = moduleName + "." + methodName
        if let cached = cache[canonical] { return (canonical, cached) }
        guard let module = modules[moduleName],
            let selector = AerisBridgeInvocation.lookup(module.target, methodName: methodName)
        else { throw BridgeFailure("METHOD_NOT_FOUND", canonical) }
        guard AerisBridgeInvocation.validate(module.target, selector: selector) else {
            throw BridgeFailure(
                "INVALID_SELECTOR", "Expected @objc func method(_ session: BridgeSession) -> Void")
        }
        let bound = ResolvedBridgeInvocation(
            target: module.target, selector: selector, permissions: module.permissions)
        cache[canonical] = bound
        return (canonical, bound)
    }
}
