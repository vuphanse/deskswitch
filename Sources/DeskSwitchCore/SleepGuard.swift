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

/// Re-evaluates headlessness once a minute (cheap local DDC enumeration only).
public func startSleepGuardTimer(config: Config, router: Router) -> Timer {
    let sleepGuard = SleepGuard()
    let timer = Timer(timeInterval: 60, repeats: true) { _ in
        sleepGuard.update(headless: router.localStatus().monitors.isEmpty,
                          enabled: config.preventSleepWhenHeadless)
    }
    timer.fire()
    RunLoop.main.add(timer, forMode: .common)
    return timer
}
