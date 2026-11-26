import Foundation
import SiliconModeKit

/// Pushes this Mac's Silicon Mode status, agents, tail logs and questions to the user's
/// Silicon Cells backend, and receives answers from the phone/web apps.
@MainActor
final class CloudSync {
    private weak var model: AppModel?
    func attach(model: AppModel) { self.model = model }
    func modeChanged() {}
    func agentsChanged() {}
}
