import Foundation
import IOKit.pwr_mgt

/// Spec Lifecycle: while headless (drives no monitors) and the config flag is on,
/// hold a power assertion so the Mac stays reachable for pull requests.
public func shouldHoldAssertion(headless: Bool, enabled: Bool) -> Bool {
    headless && enabled
}

public final class SleepGuard {
    private var assertionID = IOPMAssertionID(0)
    private var active = false

    public init() {}

    public func update(headless: Bool, enabled: Bool) {
        let wanted = shouldHoldAssertion(headless: headless, enabled: enabled)
        if wanted && !active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "deskswitch: headless agent stays reachable for pull requests" as CFString,
                &assertionID)
            active = (result == kIOReturnSuccess)
        } else if !wanted && active {
            IOPMAssertionRelease(assertionID)
            active = false
        }
    }

    deinit {
        if active { IOPMAssertionRelease(assertionID) }
    }
}

/// Re-evaluates headlessness once a minute. Evaluation runs on a background queue:
/// localStatus() performs real DDC I2C reads when displays are attached, which must
/// never block the main RunLoop (the headless case — the one that matters — is cheap).
public func startSleepGuardTimer(config: Config, router: Router) -> Timer {
    let sleepGuard = SleepGuard()
    let queue = DispatchQueue(label: "deskswitch.sleepguard", qos: .utility)
    let evaluate = {
        queue.async {
            sleepGuard.update(headless: router.localStatus().monitors.isEmpty,
                              enabled: config.preventSleepWhenHeadless)
        }
    }
    let timer = Timer(timeInterval: 60, repeats: true) { _ in evaluate() }
    evaluate()
    RunLoop.main.add(timer, forMode: .common)
    return timer
}
