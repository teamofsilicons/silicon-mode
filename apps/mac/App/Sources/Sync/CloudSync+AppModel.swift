#if !SYNC_HARNESS
import Foundation
import Observation
import SiliconModeKit

/// Adapts AppModel (the app's single source of truth) to what CloudSync reads.
@MainActor
final class AppModelSyncHost: SyncHost {
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    var cloudSyncEnabled: Bool { model?.settings.cloudSyncEnabled ?? false }

    func syncLocalState() -> SyncLocalState {
        guard let m = model else {
            return SyncLocalState(mode: .off, enteredAt: nil, lidAngle: nil, siliconAngle: nil, caffeinated: false, face: "", sessions: [])
        }
        let mode: SyncLocalState.Mode
        switch m.phase {
        case .idle: mode = .off
        case .countdown: mode = .arming
        case .active(let a): mode = a.isPanicking ? .panic : (a.locked ? .locked : .active)
        }
        return SyncLocalState(
            mode: mode,
            enteredAt: m.enteredAt,
            lidAngle: m.angle,
            siliconAngle: m.siliconModeAngle,
            caffeinated: m.caffeinator.isActive,
            face: m.settings.faceID,
            sessions: m.sessions
        )
    }

    func usageBuckets(days: Int?) -> [UsageBucket] {
        guard let m = model else { return [] }
        if let days { return m.usage.history(days: days) }
        return m.usage.recent()
    }

    /// Same effect as `AppModel.answer(_:…)`, but awaited so the outcome can be reported back.
    func applyCloudAnswer(_ q: AgentQuestion, optionIDs: [String], text: String?, source: AgentAnswer.Source) async -> SyncAnswerOutcome {
        guard let m = model else { return .failed }
        let a = AgentAnswer(questionID: q.id, optionIDs: optionIDs, text: text, source: source)
        m.answerErrors[q.id] = nil
        do {
            try await m.hub.answer(q, with: a)
            await m.refreshAgents()
            return .applied
        } catch let e as AgentAnswerError {
            switch e {
            case .notPending: return .stale
            case .unsupported: m.answerErrors[q.id] = "Answer this one in the agent's own window."
            case .failed(let msg): m.answerErrors[q.id] = msg
            }
            return .failed
        } catch {
            m.answerErrors[q.id] = error.localizedDescription
            return .failed
        }
    }
}

extension CloudSync {
    /// Called once from `AppModel.start()` (after `account.restore()`).
    func attach(model: AppModel) {
        attach(host: AppModelSyncHost(model: model), account: model.account)
        observeSyncSetting(model)
    }

    /// Settings → `cloudSyncEnabled` toggles start/stop sync without AppModel calling us.
    private func observeSyncSetting(_ model: AppModel) {
        withObservationTracking {
            _ = model.settings.cloudSyncEnabled
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.reevaluate()
                self.observeSyncSetting(model)
            }
        }
    }
}
#endif
