import Foundation
import Network

/// Bonjour browsing for receivers advertising `_mactvmirror._tcp`.
enum Discovery {
    struct Found {
        let name: String
        let endpoint: NWEndpoint
    }

    /// Browse for up to `seconds`. Returns early when `stopWhen` matches a result.
    static func browse(seconds: Double, stopWhen: ((Found) -> Bool)? = nil) -> [Found] {
        let browser = NWBrowser(for: .bonjour(type: WireProtocol.serviceType, domain: nil), using: .tcp)
        let queue = DispatchQueue(label: "mactv.browse")
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var found: [String: Found] = [:]

        browser.browseResultsChangedHandler = { results, _ in
            lock.lock()
            defer { lock.unlock() }
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    let entry = Found(name: name, endpoint: result.endpoint)
                    found[name] = entry
                    if let stopWhen, stopWhen(entry) { done.signal() }
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.warn("browse failed: \(error)")
                done.signal()
            }
        }
        browser.start(queue: queue)
        _ = done.wait(timeout: .now() + seconds)
        browser.cancel()

        lock.lock()
        defer { lock.unlock() }
        return found.values.sorted { $0.name < $1.name }
    }
}
