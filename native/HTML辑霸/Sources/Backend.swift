import Foundation
import Combine
import AppKit

/// Owns the local HTTP backend (in-process Swift server).
@MainActor
final class BackendManager: ObservableObject {
    static let shared = BackendManager()
    @Published var isRunning = false
    @Published var port: Int = 9100
    @Published var lastError: String?

    private let server = LocalHTTPServer()
    private var started = false

    func start() {
        guard !started else { return }
        do {
            try server.start(preferred: 9100)
            port = Int(server.port)
            isRunning = true
            lastError = nil
            started = true
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        server.stop()
        started = false
        isRunning = false
    }

    var baseURL: URL { server.baseURL }
}
