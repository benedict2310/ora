import Foundation

protocol AudioServicing: Sendable {
    func start() async throws -> AsyncStream<AudioFrame>
    func stop() async
    func cancel() async
}

extension AudioService: AudioServicing {}

@MainActor
protocol PersistenceServicing: AnyObject {
    var settings: AppSettings { get }
}

@MainActor
extension PersistenceManager: PersistenceServicing {}

@MainActor
protocol OverlayPresenting: AnyObject {
    var mode: OverlayMode { get set }
    var model: OverlayViewModel { get }
    var isVisible: Bool { get }
    func show()
    func hide(animated: Bool)
}

@MainActor
extension OverlayWindowController: OverlayPresenting {}
