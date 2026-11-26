import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct PinVaultTests {
    @Test func setAndVerify() throws {
        let v = PinVault(store: MemoryPinStore())
        #expect(v.verify("123456") == .notSet)
        try v.set(pin: "482913")
        #expect(v.isSet)
        #expect(v.verify("482913") == .ok)
        #expect(v.verify("000000") == .wrong(attemptsLeft: 4))
        #expect(v.verify("482913") == .ok) // success resets failures
    }

    @Test func rejectsBadFormat() {
        let v = PinVault(store: MemoryPinStore())
        #expect(throws: PinError.self) { try v.set(pin: "12345") }
        #expect(throws: PinError.self) { try v.set(pin: "12a456") }
    }

    @Test func throttlesAfterFiveFailures() throws {
        let v = PinVault(store: MemoryPinStore())
        try v.set(pin: "111111")
        let now = Date()
        for _ in 0..<4 { _ = v.verify("222222", now: now) }
        guard case .throttled(let after) = v.verify("222222", now: now) else { Issue.record("expected throttle"); return }
        #expect(after == 30)
        guard case .throttled = v.verify("111111", now: now.addingTimeInterval(10)) else { Issue.record("still throttled"); return }
        #expect(v.verify("111111", now: now.addingTimeInterval(31)) == .ok)
    }
}
