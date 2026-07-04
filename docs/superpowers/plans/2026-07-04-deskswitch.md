# deskswitch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single Swift binary, installed on both Macs, that switches the two monitors' input sources over DDC/CI from a menu bar app, CLI, or HTTP API, forwarding requests between machines over the LAN.

**Architecture:** A pure-logic core library (`DeskSwitchCore`: config, router, DDC packet codec, HTTP codec, view-model) tested with mocks, plus a thin executable (`deskswitch`) holding the hardware DDC engine (IOAVService via `dlsym`), the ArgumentParser CLI, and the SwiftUI `MenuBarExtra` app. The router decides "write DDC locally or forward to peer"; a `WakingPeerClient` decorator adds Wake-on-LAN + retry.

**Tech Stack:** Swift 5.9 / SwiftPM, macOS 14+, Apple Silicon only. Foundation, IOKit (DDC + power assertions), Network.framework (HTTP server), URLSession (peer client), SwiftUI (`MenuBarExtra`), UserNotifications, ServiceManagement (`SMAppService`). One external dependency: `swift-argument-parser`.

**Spec:** `docs/superpowers/specs/2026-07-04-deskswitch-design.md` — read it before starting.

## Global Constraints

- macOS 14+, Apple Silicon (arm64) only. Single DDC path via IOAVService; no Intel/`ddcctl` fallback (spec non-goal).
- Exactly two machines, exactly one `peer` in config. No multi-machine code paths (spec non-goal), but don't hard-fail on extra config keys.
- Only VCP code `0x60` (input select). No brightness/volume DDC (spec non-goal).
- Only external dependency: `swift-argument-parser` (from: `1.3.0`).
- Config file: `~/.config/deskswitch/config.json`. HTTP listen port default `8377`. Auth header: `X-DeskSwitch-Token` (shared static token).
- Network timeout: 2 seconds per hop; UI never blocks the main thread on network.
- Wake-on-LAN only when `peer.mac` is set; defaults `broadcastHost` `255.255.255.255`, UDP port `9`. Missing `peer.mac` → startup warning + WoL skipped (degrade to retry + notification), never a crash.
- Display disappearance after a successful push switch is SUCCESS, not an error (the display detaches because it now shows the other Mac). Never "verify" a push by reading back.
- Monitors matched by EDID product name (`M27Q`, `PA278CV`); input codes come from config, populated by `deskswitch probe` — never hardcode input codes in source.
- TDD for all pure logic (`swift test` green before every commit). Hardware/UI layers get compile checks + written verification checklists in `docs/verification/`.
- Conventional commits: `feat:` / `test:` / `chore:` / `docs:`.

## File Structure

```
Package.swift
.gitignore
Sources/DeskSwitchCore/
  Core.swift            — version constant (scaffold)
  Config.swift          — Config model, defaults, validation, load/save, code lookups
  EDID.swift            — edidDisplayName(_:) product-name parser
  DDC.swift             — DDCEngine protocol + DDC packet build/parse (pure)
  IOAVDDCEngine.swift   — hardware DDC engine (IOAVService via dlsym)
  Router.swift          — LocalStatus/MonitorStatus, RouterError(+userMessage), Router
  PeerClient.swift      — PeerClient protocol, PeerClientError, UnreachablePeerClient
  HTTP.swift            — HTTPRequest.parse, HTTPResponse.json/serialized
  APIHandler.swift      — SwitchRequest, routes, auth, RouterError→HTTP status mapping
  HTTPServer.swift      — NWListener-based HTTP server
  HTTPPeerClient.swift  — URLSession client, 2 s timeouts
  WoL.swift             — wolMagicPacket, UDPWoLSender, WakingPeerClient (M4)
  Notifier.swift        — Notifier protocol, StderrNotifier
  MenuState.swift       — MonitorRow, buildRows, MenuState view model
  CommandCore.swift     — applyProbe / statusText / probeText (pure CLI logic)
  SleepGuard.swift      — IOPM sleep-prevention assertion (M4)
Sources/deskswitch/
  main.swift            — bundle→menu bar app / args→CLI dispatch
  CLI.swift             — ArgumentParser commands (status/probe/switch/serve/autostart)
  App.swift             — Bootstrap + SwiftUI MenuBarExtra (M3)
  UserNotifier.swift    — UNUserNotificationCenter notifier (M4)
Tests/DeskSwitchCoreTests/
  ConfigTests.swift, EDIDTests.swift, DDCTests.swift, RouterTests.swift,
  HTTPTests.swift, APIHandlerTests.swift, HTTPServerTests.swift,
  HTTPPeerClientTests.swift, WoLTests.swift, MenuStateTests.swift,
  CommandCoreTests.swift, SleepGuardTests.swift, Mocks.swift
packaging/Info.plist
packaging/com.vuphan.deskswitch.plist
scripts/make-app.sh
scripts/e2e.sh
docs/verification/m1-checklist.md … m4-checklist.md
```

Tasks 1–7 are milestone M1 (DDC core + CLI), 8–12 are M2 (HTTP + router over the wire), 13–15 are M3 (menu bar UI), 16–20 are M4 (polish). Each milestone leaves a shippable tool.

---

### Task 1: SwiftPM scaffold

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/DeskSwitchCore/Core.swift`, `Sources/deskswitch/main.swift`, `Tests/DeskSwitchCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: package layout + targets `DeskSwitchCore` (library), `deskswitch` (executable), `DeskSwitchCoreTests`; constant `public let deskswitchVersion: String`.

- [ ] **Step 1: Create the package files**

`Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "deskswitch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "DeskSwitchCore"),
        .executableTarget(
            name: "deskswitch",
            dependencies: [
                "DeskSwitchCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DeskSwitchCoreTests", dependencies: ["DeskSwitchCore"]),
    ]
)
```

`.gitignore`:

```
.build/
build/
.DS_Store
*.xcodeproj
```

`Sources/DeskSwitchCore/Core.swift`:

```swift
public let deskswitchVersion = "0.1.0"
```

`Sources/deskswitch/main.swift` (placeholder, replaced in Task 7):

```swift
import DeskSwitchCore

print("deskswitch \(deskswitchVersion)")
```

`Tests/DeskSwitchCoreTests/CoreTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class CoreTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(deskswitchVersion, "0.1.0")
    }
}
```

- [ ] **Step 2: Verify build and tests**

Run: `swift test`
Expected: `Test Suite 'All tests' passed`, 1 test.

Run: `swift run deskswitch`
Expected: prints `deskswitch 0.1.0`.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved .gitignore Sources Tests
git commit -m "chore: scaffold SwiftPM package with core library, executable, and test targets"
```

---

### Task 2: Config model — decode, defaults, validation, load/save

**Files:**
- Create: `Sources/DeskSwitchCore/Config.swift`
- Test: `Tests/DeskSwitchCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by every later task):
  - `Config` with `machineName: String`, `peer: Config.Peer` (`name`, `host`, `port: Int`, `mac: String?`), `wol: Config.WoL` (`broadcastHost: String`, `port: Int`), `token: String`, `listenPort: Int`, `monitors: [String: Config.Monitor]` (`inputs: [String: UInt16]`), `preventSleepWhenHeadless: Bool`; public memberwise init.
  - `Config.load(from: URL) throws -> Config` (default `Config.defaultPath` = `~/.config/deskswitch/config.json`), `config.save(to:) throws`.
  - `config.validate() -> [ValidationIssue]` where `ValidationIssue` has `message: String`, `isError: Bool`.
  - `config.wolEnabled: Bool`, `config.inputCode(monitor:machine:) -> UInt16?`, `config.owner(of:currentCode:) -> String?`.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/ConfigTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class ConfigTests: XCTestCase {
    static let fullJSON = """
    {
      "machineName": "macmini",
      "peer": { "name": "macbook", "host": "macbook.local", "port": 8377, "mac": "aa:bb:cc:dd:ee:ff" },
      "wol": { "broadcastHost": "192.168.1.255", "port": 7 },
      "token": "secret",
      "listenPort": 9000,
      "monitors": {
        "M27Q":    { "inputs": { "macmini": 15, "macbook": 27 } },
        "PA278CV": { "inputs": { "macmini": 15, "macbook": 17 } }
      },
      "preventSleepWhenHeadless": true
    }
    """

    static let minimalJSON = """
    {
      "machineName": "macmini",
      "peer": { "name": "macbook", "host": "macbook.local", "port": 8377 },
      "token": "secret"
    }
    """

    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testDecodesFullConfig() throws {
        let c = try decode(Self.fullJSON)
        XCTAssertEqual(c.machineName, "macmini")
        XCTAssertEqual(c.peer.mac, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(c.wol.broadcastHost, "192.168.1.255")
        XCTAssertEqual(c.wol.port, 7)
        XCTAssertEqual(c.listenPort, 9000)
        XCTAssertEqual(c.monitors["M27Q"]?.inputs["macbook"], 27)
        XCTAssertTrue(c.preventSleepWhenHeadless)
    }

    func testMinimalConfigGetsDefaults() throws {
        let c = try decode(Self.minimalJSON)
        XCTAssertNil(c.peer.mac)
        XCTAssertEqual(c.wol.broadcastHost, "255.255.255.255")
        XCTAssertEqual(c.wol.port, 9)
        XCTAssertEqual(c.listenPort, 8377)
        XCTAssertEqual(c.monitors, [:])
        XCTAssertFalse(c.preventSleepWhenHeadless)
    }

    func testWolEnabledOnlyWithMac() throws {
        XCTAssertTrue(try decode(Self.fullJSON).wolEnabled)
        XCTAssertFalse(try decode(Self.minimalJSON).wolEnabled)
    }

    func testValidateMissingMacIsWarningNotError() throws {
        let issues = try decode(Self.minimalJSON).validate()
        let wol = issues.filter { $0.message.contains("Wake-on-LAN") }
        XCTAssertEqual(wol.count, 1)
        XCTAssertFalse(wol[0].isError)
    }

    func testValidateRejectsBadValues() throws {
        var c = try decode(Self.fullJSON)
        c.machineName = ""
        XCTAssertTrue(c.validate().contains { $0.isError && $0.message.contains("machineName") })

        var samePeer = try decode(Self.fullJSON)
        samePeer.peer.name = "macmini"
        XCTAssertTrue(samePeer.validate().contains { $0.isError && $0.message.contains("peer.name") })

        var badMac = try decode(Self.fullJSON)
        badMac.peer.mac = "not-a-mac"
        XCTAssertTrue(badMac.validate().contains { $0.isError && $0.message.contains("peer.mac") })

        XCTAssertFalse(try decode(Self.fullJSON).validate().contains { $0.isError })
    }

    func testLookups() throws {
        let c = try decode(Self.fullJSON)
        XCTAssertEqual(c.inputCode(monitor: "M27Q", machine: "macbook"), 27)
        XCTAssertNil(c.inputCode(monitor: "M27Q", machine: "nobody"))
        XCTAssertEqual(c.owner(of: "PA278CV", currentCode: 17), "macbook")
        XCTAssertNil(c.owner(of: "PA278CV", currentCode: 99))
    }

    func testSaveLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskswitch-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("config.json")
        let c = try decode(Self.fullJSON)
        try c.save(to: url)
        XCTAssertEqual(try Config.load(from: url), c)
        try? FileManager.default.removeItem(at: dir)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests`
Expected: compile error — `Config` not defined. (Compile failure is the failing state for a new module.)

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/Config.swift`:

```swift
import Foundation

public struct ValidationIssue: Equatable {
    public let message: String
    public let isError: Bool
    public init(message: String, isError: Bool) {
        self.message = message
        self.isError = isError
    }
}

public struct Config: Codable, Equatable {
    public var machineName: String
    public var peer: Peer
    public var wol: WoL
    public var token: String
    public var listenPort: Int
    public var monitors: [String: Monitor]
    public var preventSleepWhenHeadless: Bool

    public struct Peer: Codable, Equatable {
        public var name: String
        public var host: String
        public var port: Int
        public var mac: String?
        public init(name: String, host: String, port: Int, mac: String? = nil) {
            self.name = name
            self.host = host
            self.port = port
            self.mac = mac
        }
    }

    public struct WoL: Codable, Equatable {
        public var broadcastHost: String
        public var port: Int
        public init(broadcastHost: String = "255.255.255.255", port: Int = 9) {
            self.broadcastHost = broadcastHost
            self.port = port
        }
    }

    public struct Monitor: Codable, Equatable {
        public var inputs: [String: UInt16]
        public init(inputs: [String: UInt16]) {
            self.inputs = inputs
        }
    }

    public init(machineName: String, peer: Peer, wol: WoL = WoL(), token: String,
                listenPort: Int = 8377, monitors: [String: Monitor] = [:],
                preventSleepWhenHeadless: Bool = false) {
        self.machineName = machineName
        self.peer = peer
        self.wol = wol
        self.token = token
        self.listenPort = listenPort
        self.monitors = monitors
        self.preventSleepWhenHeadless = preventSleepWhenHeadless
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineName = try c.decode(String.self, forKey: .machineName)
        peer = try c.decode(Peer.self, forKey: .peer)
        wol = try c.decodeIfPresent(WoL.self, forKey: .wol) ?? WoL()
        token = try c.decode(String.self, forKey: .token)
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 8377
        monitors = try c.decodeIfPresent([String: Monitor].self, forKey: .monitors) ?? [:]
        preventSleepWhenHeadless = try c.decodeIfPresent(Bool.self, forKey: .preventSleepWhenHeadless) ?? false
    }

    public var wolEnabled: Bool { peer.mac != nil }

    public func inputCode(monitor: String, machine: String) -> UInt16? {
        monitors[monitor]?.inputs[machine]
    }

    public func owner(of monitor: String, currentCode: UInt16) -> String? {
        monitors[monitor]?.inputs.first(where: { $0.value == currentCode })?.key
    }

    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if machineName.isEmpty {
            issues.append(.init(message: "machineName must not be empty", isError: true))
        }
        if peer.name == machineName {
            issues.append(.init(message: "peer.name must differ from machineName", isError: true))
        }
        if !(1...65535).contains(peer.port) {
            issues.append(.init(message: "peer.port must be 1-65535", isError: true))
        }
        if !(1...65535).contains(listenPort) {
            issues.append(.init(message: "listenPort must be 1-65535", isError: true))
        }
        if token.isEmpty {
            issues.append(.init(message: "token must not be empty", isError: true))
        }
        if let mac = peer.mac {
            let pattern = "^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$"
            if mac.range(of: pattern, options: .regularExpression) == nil {
                issues.append(.init(message: "peer.mac is not a valid MAC address: \(mac)", isError: true))
            }
        } else {
            issues.append(.init(
                message: "Wake-on-LAN disabled: peer.mac not set (peer-unreachable handling degrades to retry + notification)",
                isError: false))
        }
        return issues
    }

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/deskswitch/config.json")
    }

    public static func load(from url: URL = defaultPath) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = Config.defaultPath) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/Config.swift Tests/DeskSwitchCoreTests/ConfigTests.swift
git commit -m "feat: config model with WoL defaults, validation, and load/save"
```

---

### Task 3: EDID product-name parser

**Files:**
- Create: `Sources/DeskSwitchCore/EDID.swift`
- Test: `Tests/DeskSwitchCoreTests/EDIDTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public func edidDisplayName(_ data: Data) -> String?` — used by `IOAVDDCEngine` (Task 6).

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/EDIDTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class EDIDTests: XCTestCase {
    /// Builds a 128-byte EDID block with a display-product-name descriptor (tag 0xFC)
    /// at the given descriptor slot offset (54, 72, 90, or 108).
    func makeEDID(name: String, at offset: Int = 54) -> Data {
        var edid = Data(repeating: 0, count: 128)
        edid[offset + 3] = 0xFC
        var text = Array((name + "\n").utf8)
        while text.count < 13 { text.append(0x20) }
        for (i, b) in text.prefix(13).enumerated() { edid[offset + 5 + i] = b }
        return edid
    }

    func testParsesNameFromFirstDescriptor() {
        XCTAssertEqual(edidDisplayName(makeEDID(name: "M27Q")), "M27Q")
    }

    func testParsesNameFromLaterDescriptor() {
        XCTAssertEqual(edidDisplayName(makeEDID(name: "PA278CV", at: 90)), "PA278CV")
    }

    func testTrimsPadding() {
        XCTAssertEqual(edidDisplayName(makeEDID(name: "M27Q ")), "M27Q")
    }

    func testReturnsNilWithoutNameDescriptor() {
        XCTAssertNil(edidDisplayName(Data(repeating: 0, count: 128)))
    }

    func testReturnsNilForShortData() {
        XCTAssertNil(edidDisplayName(Data(repeating: 0, count: 10)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EDIDTests`
Expected: compile error — `edidDisplayName` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/EDID.swift`:

```swift
import Foundation

/// Extracts the display product name (descriptor tag 0xFC) from a raw EDID block.
/// Descriptor slots live at offsets 54, 72, 90, 108; a display descriptor starts
/// with two zero bytes, a zero, the tag, a zero, then 13 bytes of text terminated
/// by 0x0A and padded with 0x20.
public func edidDisplayName(_ data: Data) -> String? {
    guard data.count >= 128 else { return nil }
    for offset in [54, 72, 90, 108] {
        guard data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 0,
              data[offset + 3] == 0xFC else { continue }
        let raw = data[(offset + 5)..<(offset + 18)]
        let text = String(decoding: raw, as: UTF8.self)
        let name = (text.split(separator: "\n").first.map(String.init) ?? text)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EDIDTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/EDID.swift Tests/DeskSwitchCoreTests/EDIDTests.swift
git commit -m "feat: EDID product-name parser for monitor identification"
```

---

### Task 4: DDC protocol — engine interface and packet codec

**Files:**
- Create: `Sources/DeskSwitchCore/DDC.swift`
- Test: `Tests/DeskSwitchCoreTests/DDCTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public protocol DDCEngine` with `connectedDisplayNames() throws -> [String]`, `readInput(displayName: String) throws -> UInt16`, `setInput(displayName: String, code: UInt16) throws`.
  - `DDC.inputSelect: UInt8` (= 0x60), `DDC.setVCPPacket(code:value:) -> [UInt8]`, `DDC.readVCPRequestPacket(code:) -> [UInt8]`, `DDC.parseVCPReply(_:expectedCode:) -> UInt16?`.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/DDCTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class DDCTests: XCTestCase {
    func testSetVCPPacketLayoutAndChecksum() {
        let p = DDC.setVCPPacket(code: 0x60, value: 17)
        XCTAssertEqual(Array(p.prefix(5)), [0x84, 0x03, 0x60, 0x00, 0x11])
        // Checksum XORs destination (0x6E), source (0x51), and all payload bytes.
        let expected = p.prefix(5).reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        XCTAssertEqual(p[5], expected)
        XCTAssertEqual(p.count, 6)
    }

    func testSetVCPPacketSplitsValueBytes() {
        let p = DDC.setVCPPacket(code: 0x60, value: 0x0102)
        XCTAssertEqual(p[3], 0x01)
        XCTAssertEqual(p[4], 0x02)
    }

    func testReadVCPRequestPacket() {
        let p = DDC.readVCPRequestPacket(code: 0x60)
        XCTAssertEqual(Array(p.prefix(3)), [0x82, 0x01, 0x60])
        let expected = p.prefix(3).reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        XCTAssertEqual(p[3], expected)
    }

    func testParseVCPReplyExtractsCurrentValue() {
        // opcode 0x02, result 0x00, code 0x60, type, maxH, maxL, curH, curL
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x1B, 0x00, 0x0F, 0x00, 0x00]
        XCTAssertEqual(DDC.parseVCPReply(reply, expectedCode: 0x60), 15)
    }

    func testParseVCPReplyToleratesMissingAddressPrefix() {
        let reply: [UInt8] = [0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x1B, 0x00, 0x1B, 0x00, 0x00]
        XCTAssertEqual(DDC.parseVCPReply(reply, expectedCode: 0x60), 27)
    }

    func testParseVCPReplyRejectsWrongCodeOrError() {
        let wrongCode: [UInt8] = [0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00, 0x00]
        XCTAssertNil(DDC.parseVCPReply(wrongCode, expectedCode: 0x60))
        let errorResult: [UInt8] = [0x88, 0x02, 0x01, 0x60, 0x00, 0x00, 0x1B, 0x00, 0x0F, 0x00, 0x00]
        XCTAssertNil(DDC.parseVCPReply(errorResult, expectedCode: 0x60))
        XCTAssertNil(DDC.parseVCPReply([0x02, 0x00], expectedCode: 0x60))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DDCTests`
Expected: compile error — `DDC` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/DDC.swift`:

```swift
import Foundation

/// Abstraction over the hardware DDC path so router/UI/CLI logic tests with a mock.
public protocol DDCEngine {
    /// EDID product names of external displays this Mac currently drives.
    func connectedDisplayNames() throws -> [String]
    func readInput(displayName: String) throws -> UInt16
    func setInput(displayName: String, code: UInt16) throws
}

public enum DDC {
    public static let inputSelect: UInt8 = 0x60

    // DDC/CI framing: destination 0x6E, source 0x51; checksum XORs both plus payload.
    private static func checksum(_ payload: [UInt8]) -> UInt8 {
        payload.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
    }

    public static func setVCPPacket(code: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        p.append(checksum(p))
        return p
    }

    public static func readVCPRequestPacket(code: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x82, 0x01, code]
        p.append(checksum(p))
        return p
    }

    /// Parses a Get-VCP reply. Monitors differ in whether the buffer starts with the
    /// address/length bytes, so scan for the reply opcode (0x02) with result 0x00 and
    /// the echoed VCP code; the current value is the last two bytes of that record.
    public static func parseVCPReply(_ reply: [UInt8], expectedCode: UInt8) -> UInt16? {
        guard reply.count >= 8 else { return nil }
        for i in 0...(reply.count - 8)
        where reply[i] == 0x02 && reply[i + 1] == 0x00 && reply[i + 2] == expectedCode {
            return UInt16(reply[i + 6]) << 8 | UInt16(reply[i + 7])
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DDCTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/DDC.swift Tests/DeskSwitchCoreTests/DDCTests.swift
git commit -m "feat: DDC engine protocol and VCP packet codec"
```

---

### Task 5: Router — the decision brain

**Files:**
- Create: `Sources/DeskSwitchCore/Router.swift`, `Sources/DeskSwitchCore/PeerClient.swift`, `Tests/DeskSwitchCoreTests/Mocks.swift`
- Test: `Tests/DeskSwitchCoreTests/RouterTests.swift`

**Interfaces:**
- Consumes: `Config` (Task 2), `DDCEngine` (Task 4).
- Produces:
  - `public protocol PeerClient` with `status() throws -> LocalStatus` and `requestSwitch(monitor: String, target: String, forwarded: Bool) throws`; `PeerClientError` enum (`unreachable`, `remote(status: Int, message: String)`); `UnreachablePeerClient` stub.
  - `LocalStatus` (`machine: String`, `monitors: [MonitorStatus]`), `MonitorStatus` (`name`, `inputCode: UInt16`, `owner: String?`) — both `Codable, Equatable`.
  - `Router(config:ddc:peer:)` with `localStatus() -> LocalStatus`, `switchMonitor(_:to:allowForward:) throws -> SwitchOutcome`, `switchAll(to:) -> [(monitor: String, result: Result<SwitchOutcome, RouterError>)]`.
  - `SwitchOutcome` (`switchedLocally`, `forwarded`); `RouterError` (`unknownMonitor`, `missingInputCode`, `nobodyDrives`, `peerUnreachable`, `ddcFailure`) with `var userMessage: String`.
  - Test mocks `MockDDCEngine`, `MockPeerClient`, and fixture `func testConfig() -> Config` in `Mocks.swift`.

- [ ] **Step 1: Write the mocks and failing tests**

`Tests/DeskSwitchCoreTests/Mocks.swift`:

```swift
import Foundation
@testable import DeskSwitchCore

enum MockError: Error { case noValue, setFailed }

final class MockDDCEngine: DDCEngine {
    var names: [String] = []
    var inputs: [String: UInt16] = [:]
    var setCalls: [(name: String, code: UInt16)] = []
    var failSet = false

    func connectedDisplayNames() throws -> [String] { names }

    func readInput(displayName: String) throws -> UInt16 {
        guard let v = inputs[displayName] else { throw MockError.noValue }
        return v
    }

    func setInput(displayName: String, code: UInt16) throws {
        if failSet { throw MockError.setFailed }
        setCalls.append((displayName, code))
        inputs[displayName] = code
    }
}

final class MockPeerClient: PeerClient {
    var statusResult: Result<LocalStatus, PeerClientError> = .failure(.unreachable)
    var switchError: PeerClientError?
    var switchCalls: [(monitor: String, target: String, forwarded: Bool)] = []

    func status() throws -> LocalStatus {
        try statusResult.get()
    }

    func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        switchCalls.append((monitor, target, forwarded))
        if let e = switchError { throw e }
    }
}

func testConfig() -> Config {
    Config(
        machineName: "macmini",
        peer: .init(name: "macbook", host: "macbook.local", port: 8377, mac: "aa:bb:cc:dd:ee:ff"),
        token: "secret",
        monitors: [
            "M27Q": .init(inputs: ["macmini": 15, "macbook": 27]),
            "PA278CV": .init(inputs: ["macmini": 15, "macbook": 17]),
        ])
}
```

`Tests/DeskSwitchCoreTests/RouterTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class RouterTests: XCTestCase {
    var ddc = MockDDCEngine()
    var peer = MockPeerClient()

    func makeRouter() -> Router {
        Router(config: testConfig(), ddc: ddc, peer: peer)
    }

    func testSwitchesLocallyWhenThisMacDrivesTheMonitor() throws {
        ddc.names = ["M27Q"]
        let outcome = try makeRouter().switchMonitor("M27Q", to: "macbook")
        XCTAssertEqual(outcome, .switchedLocally)
        XCTAssertEqual(ddc.setCalls.count, 1)
        XCTAssertEqual(ddc.setCalls[0].code, 27)
        XCTAssertTrue(peer.switchCalls.isEmpty)
    }

    func testForwardsWhenPeerDrivesTheMonitor() throws {
        ddc.names = []
        let outcome = try makeRouter().switchMonitor("M27Q", to: "macmini")
        XCTAssertEqual(outcome, .forwarded)
        XCTAssertEqual(peer.switchCalls.count, 1)
        XCTAssertEqual(peer.switchCalls[0].monitor, "M27Q")
        XCTAssertTrue(peer.switchCalls[0].forwarded)
    }

    func testForwardedRequestNeverReForwards() {
        ddc.names = []
        XCTAssertThrowsError(
            try makeRouter().switchMonitor("M27Q", to: "macmini", allowForward: false)
        ) { XCTAssertEqual($0 as? RouterError, .nobodyDrives("M27Q")) }
        XCTAssertTrue(peer.switchCalls.isEmpty)
    }

    func testUnknownMonitor() {
        XCTAssertThrowsError(try makeRouter().switchMonitor("LG99", to: "macbook")) {
            XCTAssertEqual($0 as? RouterError, .unknownMonitor("LG99"))
        }
    }

    func testMissingInputCode() {
        ddc.names = ["M27Q"]
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "ghost")) {
            XCTAssertEqual($0 as? RouterError, .missingInputCode(monitor: "M27Q", machine: "ghost"))
        }
        XCTAssertTrue(RouterError.missingInputCode(monitor: "M27Q", machine: "ghost")
            .userMessage.contains("deskswitch probe"))
    }

    func testDDCFailureSurfaces() {
        ddc.names = ["M27Q"]
        ddc.failSet = true
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "macbook")) {
            guard case .ddcFailure = $0 as? RouterError else { return XCTFail("expected ddcFailure") }
        }
    }

    func testPeerUnreachableSurfaces() {
        ddc.names = []
        peer.switchError = .unreachable
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "macmini")) {
            XCTAssertEqual($0 as? RouterError, .peerUnreachable)
        }
    }

    func testPeer409MapsToNobodyDrives() {
        ddc.names = []
        peer.switchError = .remote(status: 409, message: "no machine currently drives 'M27Q'")
        XCTAssertThrowsError(try makeRouter().switchMonitor("M27Q", to: "macmini")) {
            XCTAssertEqual($0 as? RouterError, .nobodyDrives("M27Q"))
        }
    }

    func testLocalStatusReportsOwners() {
        ddc.names = ["M27Q", "PA278CV"]
        ddc.inputs = ["M27Q": 15, "PA278CV": 99]
        let s = makeRouter().localStatus()
        XCTAssertEqual(s.machine, "macmini")
        XCTAssertEqual(s.monitors.count, 2)
        XCTAssertEqual(s.monitors.first { $0.name == "M27Q" }?.owner, "macmini")
        XCTAssertNil(s.monitors.first { $0.name == "PA278CV" }?.owner)
    }

    func testSwitchAllCoversEveryConfiguredMonitorSorted() {
        ddc.names = ["M27Q", "PA278CV"]
        let results = makeRouter().switchAll(to: "macbook")
        XCTAssertEqual(results.map(\.monitor), ["M27Q", "PA278CV"])
        XCTAssertEqual(ddc.setCalls.count, 2)
        for r in results {
            XCTAssertEqual(try? r.result.get(), .switchedLocally)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RouterTests`
Expected: compile error — `Router`, `PeerClient` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/PeerClient.swift`:

```swift
import Foundation

public enum PeerClientError: Error, Equatable {
    case unreachable
    case remote(status: Int, message: String)
}

public protocol PeerClient {
    func status() throws -> LocalStatus
    func requestSwitch(monitor: String, target: String, forwarded: Bool) throws
}

/// M1 stand-in until the HTTP client exists: every peer call fails as unreachable.
public struct UnreachablePeerClient: PeerClient {
    public init() {}
    public func status() throws -> LocalStatus { throw PeerClientError.unreachable }
    public func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        throw PeerClientError.unreachable
    }
}
```

`Sources/DeskSwitchCore/Router.swift`:

```swift
import Foundation

public struct MonitorStatus: Codable, Equatable {
    public let name: String
    public let inputCode: UInt16
    public let owner: String?
    public init(name: String, inputCode: UInt16, owner: String?) {
        self.name = name
        self.inputCode = inputCode
        self.owner = owner
    }
}

public struct LocalStatus: Codable, Equatable {
    public let machine: String
    public let monitors: [MonitorStatus]
    public init(machine: String, monitors: [MonitorStatus]) {
        self.machine = machine
        self.monitors = monitors
    }
}

public enum SwitchOutcome: Equatable {
    case switchedLocally
    case forwarded
}

public enum RouterError: Error, Equatable {
    case unknownMonitor(String)
    case missingInputCode(monitor: String, machine: String)
    case nobodyDrives(String)
    case peerUnreachable
    case ddcFailure(String)

    public var userMessage: String {
        switch self {
        case .unknownMonitor(let m):
            return "unknown monitor '\(m)' — not present in config"
        case .missingInputCode(let m, let machine):
            return "no input code for monitor '\(m)' / machine '\(machine)' — run `deskswitch probe` on the machine that drives it"
        case .nobodyDrives(let m):
            return "no machine currently drives '\(m)'"
        case .peerUnreachable:
            return "other Mac offline"
        case .ddcFailure(let detail):
            return "DDC write failed: \(detail)"
        }
    }
}

public struct Router {
    private let config: Config
    private let ddc: DDCEngine
    private let peer: PeerClient

    public init(config: Config, ddc: DDCEngine, peer: PeerClient) {
        self.config = config
        self.ddc = ddc
        self.peer = peer
    }

    public func localStatus() -> LocalStatus {
        let names = (try? ddc.connectedDisplayNames()) ?? []
        let monitors: [MonitorStatus] = names.sorted().compactMap { name in
            guard let code = try? ddc.readInput(displayName: name) else { return nil }
            return MonitorStatus(name: name, inputCode: code,
                                 owner: config.owner(of: name, currentCode: code))
        }
        return LocalStatus(machine: config.machineName, monitors: monitors)
    }

    /// Spec routing rules: drive locally → DDC write; else forward once to the peer;
    /// a request that was already forwarded must not bounce back (nobodyDrives).
    public func switchMonitor(_ monitor: String, to target: String,
                              allowForward: Bool = true) throws -> SwitchOutcome {
        guard config.monitors[monitor] != nil else {
            throw RouterError.unknownMonitor(monitor)
        }
        let local = (try? ddc.connectedDisplayNames()) ?? []
        if local.contains(monitor) {
            guard let code = config.inputCode(monitor: monitor, machine: target) else {
                throw RouterError.missingInputCode(monitor: monitor, machine: target)
            }
            do {
                try ddc.setInput(displayName: monitor, code: code)
            } catch {
                throw RouterError.ddcFailure("\(error)")
            }
            return .switchedLocally
        }
        guard allowForward else {
            throw RouterError.nobodyDrives(monitor)
        }
        do {
            try peer.requestSwitch(monitor: monitor, target: target, forwarded: true)
            return .forwarded
        } catch PeerClientError.unreachable {
            throw RouterError.peerUnreachable
        } catch let PeerClientError.remote(status, message) {
            if status == 409 { throw RouterError.nobodyDrives(monitor) }
            throw RouterError.ddcFailure(message)
        }
    }

    public func switchAll(to target: String) -> [(monitor: String, result: Result<SwitchOutcome, RouterError>)] {
        config.monitors.keys.sorted().map { monitor in
            do {
                return (monitor, .success(try switchMonitor(monitor, to: target)))
            } catch let e as RouterError {
                return (monitor, .failure(e))
            } catch {
                return (monitor, .failure(.ddcFailure("\(error)")))
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RouterTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/Router.swift Sources/DeskSwitchCore/PeerClient.swift \
        Tests/DeskSwitchCoreTests/Mocks.swift Tests/DeskSwitchCoreTests/RouterTests.swift
git commit -m "feat: router with local-switch/forward decision logic and loop guard"
```

---

### Task 6: Hardware DDC engine (IOAVService)

**Files:**
- Create: `Sources/DeskSwitchCore/IOAVDDCEngine.swift`

**Interfaces:**
- Consumes: `DDCEngine`, `DDC` (Task 4), `edidDisplayName` (Task 3).
- Produces: `public final class IOAVDDCEngine: DDCEngine` with `public init() throws`; `EngineError` enum. Used by CLI (Task 7) and app bootstrap (Task 14).

This layer talks to private-but-exported IOKit symbols (`IOAVService*`) resolved at runtime with `dlsym` — the same mechanism `m1ddc` uses. It is deliberately NOT unit-tested (spec: "no mocked-IOKit theater"); it is verified on real hardware via the M1 checklist (Task 7). The step here is: write it, make it compile, hardware-verify later.

Critical behavior: the engine re-enumerates displays on EVERY operation instead of caching a boot-time snapshot. Monitors move between Macs at runtime — that is the whole point of this tool — and long-running agents (`serve`, the menu bar app) must see a monitor that just appeared (pull flow) or vanished (peer pushed it away) without restarting. Enumeration is a cheap IORegistry walk and operations are seconds apart, so this is not hot-path.

- [ ] **Step 1: Write the implementation**

`Sources/DeskSwitchCore/IOAVDDCEngine.swift`:

```swift
import Foundation
import IOKit

/// Runtime bindings for the Apple Silicon display service I2C API. These symbols are
/// exported by the system but not declared in public headers; resolve via dlsym like
/// m1ddc does. If resolution fails the engine refuses to construct.
private struct IOAVSymbols {
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    typealias CopyEDIDFn = @convention(c) (AnyObject, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    typealias ReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    let createWithService: CreateWithServiceFn
    let copyEDID: CopyEDIDFn
    let readI2C: ReadI2CFn
    let writeI2C: WriteI2CFn

    static func load() -> IOAVSymbols? {
        let handle = dlopen(nil, RTLD_NOW)
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let edid = dlsym(handle, "IOAVServiceCopyEDID"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return IOAVSymbols(
            createWithService: unsafeBitCast(create, to: CreateWithServiceFn.self),
            copyEDID: unsafeBitCast(edid, to: CopyEDIDFn.self),
            readI2C: unsafeBitCast(read, to: ReadI2CFn.self),
            writeI2C: unsafeBitCast(write, to: WriteI2CFn.self))
    }
}

public final class IOAVDDCEngine: DDCEngine {
    public enum EngineError: Error, CustomStringConvertible {
        case symbolsUnavailable
        case displayNotFound(String)
        case i2cError(String)
        case badReply(String)

        public var description: String {
            switch self {
            case .symbolsUnavailable:
                return "IOAVService symbols unavailable (Apple Silicon required)"
            case .displayNotFound(let n):
                return "display '\(n)' is not driven by this Mac"
            case .i2cError(let d):
                return "I2C transfer failed: \(d)"
            case .badReply(let d):
                return "unparseable DDC reply: \(d)"
            }
        }
    }

    // DDC/CI over I2C: chip address 0x37, data/register address 0x51.
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private let symbols: IOAVSymbols
    private var services: [String: AnyObject] = [:]
    // The HTTP server queue and the UI's background refresh share one engine instance;
    // discover() mutates the cache, so every public entry point serializes on this lock.
    private let lock = NSLock()

    public init() throws {
        guard let s = IOAVSymbols.load() else { throw EngineError.symbolsUnavailable }
        symbols = s
    }

    /// Finds external displays: DCPAVServiceProxy registry entries with Location=External,
    /// keyed by EDID product name. Called before every operation — never trust a stale
    /// snapshot, because monitors attach/detach at runtime as they switch between Macs.
    private func discover() {
        services.removeAll()
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let location = IORegistryEntryCreateCFProperty(
                    service, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  location == "External",
                  let av = symbols.createWithService(kCFAllocatorDefault, service)?
                    .takeRetainedValue() else { continue }
            var edidRef: Unmanaged<CFData>?
            guard symbols.copyEDID(av, &edidRef) == KERN_SUCCESS,
                  let edid = edidRef?.takeRetainedValue() as Data? else { continue }
            if let name = edidDisplayName(edid) {
                services[name] = av
            }
        }
    }

    public func connectedDisplayNames() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        discover()
        return Array(services.keys).sorted()
    }

    /// Rediscovers, then resolves — a monitor that just appeared (pull flow) or vanished
    /// (peer pushed it away) is seen without restarting the agent.
    private func service(for displayName: String) throws -> AnyObject {
        discover()
        guard let av = services[displayName] else {
            throw EngineError.displayNotFound(displayName)
        }
        return av
    }

    public func readInput(displayName: String) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        let av = try service(for: displayName)
        var request = DDC.readVCPRequestPacket(code: DDC.inputSelect)
        guard symbols.writeI2C(av, Self.chipAddress, Self.dataAddress,
                               &request, UInt32(request.count)) == KERN_SUCCESS else {
            throw EngineError.i2cError("read request to \(displayName)")
        }
        usleep(50_000)  // DDC/CI requires ≥40 ms between request and reply
        var reply = [UInt8](repeating: 0, count: 12)
        guard symbols.readI2C(av, Self.chipAddress, Self.dataAddress,
                              &reply, UInt32(reply.count)) == KERN_SUCCESS else {
            throw EngineError.i2cError("reply read from \(displayName)")
        }
        guard let value = DDC.parseVCPReply(reply, expectedCode: DDC.inputSelect) else {
            throw EngineError.badReply(reply.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        return value
    }

    public func setInput(displayName: String, code: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        let av = try service(for: displayName)
        var packet = DDC.setVCPPacket(code: DDC.inputSelect, value: code)
        // Spec: retry once on failure. No read-back verification: a successful push
        // detaches the display from this Mac, so absence afterwards is success.
        for attempt in 0..<2 {
            if symbols.writeI2C(av, Self.chipAddress, Self.dataAddress,
                                &packet, UInt32(packet.count)) == KERN_SUCCESS {
                return
            }
            if attempt == 0 { usleep(100_000) }
        }
        throw EngineError.i2cError("set input on \(displayName)")
    }
}
```

- [ ] **Step 2: Verify it compiles and existing tests still pass**

Run: `swift test`
Expected: PASS (28 tests so far, none exercising IOAVDDCEngine).

- [ ] **Step 3: Commit**

```bash
git add Sources/DeskSwitchCore/IOAVDDCEngine.swift
git commit -m "feat: IOAVService-backed hardware DDC engine for Apple Silicon"
```

---

### Task 7: CLI — status, probe, switch + M1 hardware checklist

**Files:**
- Create: `Sources/DeskSwitchCore/CommandCore.swift`, `Sources/deskswitch/CLI.swift`, `docs/verification/m1-checklist.md`
- Modify: `Sources/deskswitch/main.swift`
- Test: `Tests/DeskSwitchCoreTests/CommandCoreTests.swift`

**Interfaces:**
- Consumes: `Config`, `Router`, `IOAVDDCEngine`, `UnreachablePeerClient`, `LocalStatus`, `RouterError.userMessage`.
- Produces:
  - `CommandCore.applyProbe(readings: [String: UInt16], config: Config) -> Config`
  - `CommandCore.probeText(readings: [String: UInt16], machine: String) -> String`
  - `CommandCore.statusText(local: LocalStatus, peer: LocalStatus?) -> String`
  - `DeskSwitchCLI: ParsableCommand` with subcommands `Status`, `Probe`, `Switch` (Serve added Task 12, Autostart Task 19); `makePeerClient(config:) -> PeerClient` factory in `CLI.swift` that Tasks 12/16 modify.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/CommandCoreTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class CommandCoreTests: XCTestCase {
    func testApplyProbeRecordsCodesForThisMachineOnly() {
        var config = testConfig()
        config.monitors["M27Q"]?.inputs["macmini"] = 99  // stale value gets overwritten
        let updated = CommandCore.applyProbe(readings: ["M27Q": 15, "NEWMON": 18], config: config)
        XCTAssertEqual(updated.monitors["M27Q"]?.inputs["macmini"], 15)
        XCTAssertEqual(updated.monitors["M27Q"]?.inputs["macbook"], 27)  // untouched
        XCTAssertEqual(updated.monitors["NEWMON"]?.inputs, ["macmini": 18])  // new entry
        XCTAssertEqual(updated.monitors["PA278CV"], config.monitors["PA278CV"])  // untouched
    }

    func testProbeText() {
        let text = CommandCore.probeText(readings: ["PA278CV": 15, "M27Q": 15], machine: "macmini")
        XCTAssertEqual(text, "M27Q: recorded input 15 for macmini\nPA278CV: recorded input 15 for macmini")
    }

    func testStatusTextWithPeer() {
        let local = LocalStatus(machine: "macmini", monitors: [
            MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini"),
        ])
        let peer = LocalStatus(machine: "macbook", monitors: [
            MonitorStatus(name: "PA278CV", inputCode: 17, owner: "macbook"),
        ])
        XCTAssertEqual(CommandCore.statusText(local: local, peer: peer), """
        [macmini]
          M27Q: input 15 (macmini)
        [macbook]
          PA278CV: input 17 (macbook)
        """)
    }

    func testStatusTextUnreachablePeerAndHeadless() {
        let local = LocalStatus(machine: "macmini", monitors: [])
        XCTAssertEqual(CommandCore.statusText(local: local, peer: nil), """
        [macmini]
          drives no external displays
        [peer] unreachable
        """)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandCoreTests`
Expected: compile error — `CommandCore` not defined.

- [ ] **Step 3: Write CommandCore**

`Sources/DeskSwitchCore/CommandCore.swift`:

```swift
import Foundation

/// Pure logic behind the CLI subcommands, kept in Core so it is unit-testable.
public enum CommandCore {
    public static func applyProbe(readings: [String: UInt16], config: Config) -> Config {
        var updated = config
        for (name, code) in readings {
            var monitor = updated.monitors[name] ?? Config.Monitor(inputs: [:])
            monitor.inputs[updated.machineName] = code
            updated.monitors[name] = monitor
        }
        return updated
    }

    public static func probeText(readings: [String: UInt16], machine: String) -> String {
        readings.keys.sorted()
            .map { "\($0): recorded input \(readings[$0]!) for \(machine)" }
            .joined(separator: "\n")
    }

    public static func statusText(local: LocalStatus, peer: LocalStatus?) -> String {
        var lines = section(for: local)
        if let peer {
            lines += section(for: peer)
        } else {
            lines.append("[peer] unreachable")
        }
        return lines.joined(separator: "\n")
    }

    private static func section(for status: LocalStatus) -> [String] {
        var lines = ["[\(status.machine)]"]
        if status.monitors.isEmpty {
            lines.append("  drives no external displays")
        }
        lines += status.monitors.map { "  \($0.name): input \($0.inputCode) (\($0.owner ?? "unmapped"))" }
        return lines
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CommandCoreTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write the CLI and entry point**

`Sources/deskswitch/CLI.swift`:

```swift
import ArgumentParser
import DeskSwitchCore
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(1)
}

func loadValidatedConfig() -> Config {
    let config: Config
    do {
        config = try Config.load()
    } catch {
        fail("cannot read \(Config.defaultPath.path): \(error)")
    }
    for issue in config.validate() {
        FileHandle.standardError.write(Data(("config: " + issue.message + "\n").utf8))
    }
    if config.validate().contains(where: { $0.isError }) {
        fail("config invalid — fix the errors above")
    }
    return config
}

/// Peer client factory. M1: no HTTP client yet, so the peer is always unreachable.
/// (Task 12 swaps in HTTPPeerClient; Task 16 wraps it in WakingPeerClient.)
func makePeerClient(config: Config) -> PeerClient {
    UnreachablePeerClient()
}

func makeRouter(config: Config) -> Router {
    do {
        return Router(config: config, ddc: try IOAVDDCEngine(), peer: makePeerClient(config: config))
    } catch {
        fail("\(error)")
    }
}

struct DeskSwitchCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deskswitch",
        abstract: "Programmatic monitor input switching between two Macs (DDC/CI).",
        version: deskswitchVersion,
        subcommands: [Status.self, Probe.self, Switch.self])
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show which Mac drives each monitor.")

    func run() throws {
        let config = loadValidatedConfig()
        let router = makeRouter(config: config)
        let peerStatus = try? makePeerClient(config: config).status()
        print(CommandCore.statusText(local: router.localStatus(), peer: peerStatus))
    }
}

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record current input codes for displays this Mac drives into config.")

    func run() throws {
        var config = loadValidatedConfig()
        let engine: IOAVDDCEngine
        do {
            engine = try IOAVDDCEngine()
        } catch {
            fail("\(error)")
        }
        var readings: [String: UInt16] = [:]
        for name in try engine.connectedDisplayNames() {
            readings[name] = try engine.readInput(displayName: name)
        }
        guard !readings.isEmpty else {
            print("No external displays driven by this Mac; nothing to probe.")
            return
        }
        config = CommandCore.applyProbe(readings: readings, config: config)
        try config.save()
        print(CommandCore.probeText(readings: readings, machine: config.machineName))
    }
}

struct Switch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switch a monitor's input to the given machine.")

    @Argument(help: "Monitor name from config (e.g. M27Q).")
    var monitor: String

    @Argument(help: "Target machine name (this machine or the peer).")
    var machine: String

    func run() throws {
        let config = loadValidatedConfig()
        do {
            let outcome = try makeRouter(config: config).switchMonitor(monitor, to: machine)
            print(outcome == .switchedLocally ? "switched locally" : "forwarded to peer")
        } catch let e as RouterError {
            fail(e.userMessage)
        }
    }
}
```

`Sources/deskswitch/main.swift` (replace placeholder; the app-bundle branch becomes real in Task 14):

```swift
import Foundation

// Launched as an app bundle with no arguments → menu bar app (from Task 14).
// Launched from a terminal or with arguments → CLI.
DeskSwitchCLI.main()
```

- [ ] **Step 6: Verify build and full test suite**

Run: `swift test && swift build`
Expected: all tests PASS; build succeeds.

Run: `swift run deskswitch --help`
Expected: usage text listing `status`, `probe`, `switch`.

- [ ] **Step 7: Write the M1 hardware checklist**

`docs/verification/m1-checklist.md`:

```markdown
# M1 Hardware Verification — DDC core + CLI

Prerequisite: create `~/.config/deskswitch/config.json` on each Mac (see spec §Config;
`monitors` may start empty — probe fills it). Run every step on BOTH Macs unless noted.

- [ ] `swift run deskswitch status` lists the monitor(s) this Mac drives, named `M27Q` / `PA278CV`
- [ ] `swift run deskswitch probe` prints recorded codes and writes them into config
- [ ] Verify probed codes appear in `~/.config/deskswitch/config.json` under this machine's name
- [ ] After probing on both Macs, merge both machines' codes into BOTH config files (each
      file needs the full `inputs` map per monitor)
- [ ] Push: `swift run deskswitch switch M27Q <other-machine>` flips that monitor away;
      command prints `switched locally` and exits 0 (display disappearing = success)
- [ ] Repeat push for `PA278CV`
- [ ] `swift run deskswitch switch M27Q <this-machine>` while the monitor is elsewhere
      prints `other Mac offline` (M1 has no forwarding yet) and exits 1
- [ ] `swift run deskswitch switch M27Q nobody` errors mentioning `deskswitch probe`
- [ ] M27Q flakiness check (spec risk): if probe/switch misbehaves, note the cable path;
      re-cable that machine to DisplayPort/USB-C and retest
```

- [ ] **Step 8: Commit**

```bash
git add Sources/DeskSwitchCore/CommandCore.swift Sources/deskswitch \
        Tests/DeskSwitchCoreTests/CommandCoreTests.swift docs/verification/m1-checklist.md
git commit -m "feat: CLI with status, probe, and switch commands (M1 complete)"
```

---

### Task 8: HTTP codec — request parser and response serializer

**Files:**
- Create: `Sources/DeskSwitchCore/HTTP.swift`
- Test: `Tests/DeskSwitchCoreTests/HTTPTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `HTTPRequest` (`method`, `path`, `headers: [String: String]` lowercased keys, `body: Data`) with `static func parse(_ data: Data) -> ParseResult`; `ParseResult` = `.incomplete | .invalid | .request(HTTPRequest)`.
  - `HTTPResponse` (`status: Int`, `body: Data`) with `static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse` and `func serialized() -> Data`.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/HTTPTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class HTTPTests: XCTestCase {
    func testParsesGetWithHeaders() throws {
        let raw = Data("GET /status HTTP/1.1\r\nHost: x\r\nX-DeskSwitch-Token: secret\r\n\r\n".utf8)
        guard case .request(let req) = HTTPRequest.parse(raw) else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/status")
        XCTAssertEqual(req.headers["x-deskswitch-token"], "secret")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testParsesPostBodyUsingContentLength() throws {
        let body = #"{"monitor":"M27Q","target":"macmini"}"#
        let raw = Data("POST /switch HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        guard case .request(let req) = HTTPRequest.parse(raw) else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), body)
    }

    func testIncompleteHeaderAndIncompleteBody() {
        XCTAssertEqual(HTTPRequest.parse(Data("GET /status HTT".utf8)), .incomplete)
        let partial = Data("POST /switch HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"mon".utf8)
        XCTAssertEqual(HTTPRequest.parse(partial), .incomplete)
    }

    func testInvalidRequestLine() {
        XCTAssertEqual(HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)), .invalid)
    }

    func testResponseSerialization() {
        let resp = HTTPResponse.json(200, ["ok": "yes"])
        let text = String(decoding: resp.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("Content-Length: \(resp.body.count)"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + #"{"ok":"yes"}"#))
    }

    func testErrorResponseStatusLine() {
        let resp = HTTPResponse.json(409, ["error": "x"])
        XCTAssertTrue(String(decoding: resp.serialized(), as: UTF8.self).hasPrefix("HTTP/1.1 409 "))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HTTPTests`
Expected: compile error — `HTTPRequest` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/HTTP.swift`:

```swift
import Foundation

public enum ParseResult: Equatable {
    case incomplete
    case invalid
    case request(HTTPRequest)
}

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]  // keys lowercased
    public var body: Data

    public static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return .request(HTTPRequest(method: String(requestLine[0]),
                                    path: String(requestLine[1]),
                                    headers: headers, body: body))
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var body: Data

    public static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return HTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    public func serialized() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       409: "Conflict", 422: "Unprocessable Entity", 500: "Internal Server Error",
                       502: "Bad Gateway"]
        var out = Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HTTPTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/HTTP.swift Tests/DeskSwitchCoreTests/HTTPTests.swift
git commit -m "feat: minimal HTTP/1.1 request parser and JSON response serializer"
```

---

### Task 9: API handler — routes, auth, error mapping

**Files:**
- Create: `Sources/DeskSwitchCore/APIHandler.swift`
- Test: `Tests/DeskSwitchCoreTests/APIHandlerTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest`/`HTTPResponse` (Task 8), `Router`, `RouterError.userMessage`, `LocalStatus` (Task 5).
- Produces:
  - `SwitchRequest: Codable` (`monitor: String`, `target: String`, `forwarded: Bool` defaulting false when absent) — also used by `HTTPPeerClient` (Task 11).
  - `APIHandler(router:token:)` with `func handle(_ req: HTTPRequest) -> HTTPResponse` and `static func status(for: RouterError) -> Int`.
  - Error body shape: `{"error": "<message>"}`.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/APIHandlerTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class APIHandlerTests: XCTestCase {
    var ddc = MockDDCEngine()
    var peer = MockPeerClient()

    func makeHandler() -> APIHandler {
        APIHandler(router: Router(config: testConfig(), ddc: ddc, peer: peer), token: "secret")
    }

    func request(_ method: String, _ path: String, token: String? = "secret",
                 body: String = "") -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["x-deskswitch-token"] = token }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    func bodyJSON(_ resp: HTTPResponse) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: resp.body)) ?? [:]
    }

    func testRejectsMissingOrWrongToken() {
        XCTAssertEqual(makeHandler().handle(request("GET", "/status", token: nil)).status, 401)
        XCTAssertEqual(makeHandler().handle(request("GET", "/status", token: "wrong")).status, 401)
    }

    func testStatusEndpoint() throws {
        ddc.names = ["M27Q"]
        ddc.inputs = ["M27Q": 15]
        let resp = makeHandler().handle(request("GET", "/status"))
        XCTAssertEqual(resp.status, 200)
        let status = try JSONDecoder().decode(LocalStatus.self, from: resp.body)
        XCTAssertEqual(status.machine, "macmini")
        XCTAssertEqual(status.monitors, [MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini")])
    }

    func testSwitchLocal() {
        ddc.names = ["M27Q"]
        let resp = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"macbook"}"#))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyJSON(resp)["outcome"], "switched-locally")
        XCTAssertEqual(ddc.setCalls.first?.code, 27)
    }

    func testForwardedFlagBlocksReForwarding() {
        ddc.names = []
        let resp = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"macmini","forwarded":true}"#))
        XCTAssertEqual(resp.status, 409)
        XCTAssertTrue(peer.switchCalls.isEmpty)
    }

    func testErrorStatusMapping() {
        ddc.names = []
        peer.switchError = .unreachable
        let unreachable = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"macmini"}"#))
        XCTAssertEqual(unreachable.status, 502)

        let unknown = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"LG99","target":"macmini"}"#))
        XCTAssertEqual(unknown.status, 404)

        ddc.names = ["M27Q"]
        let missing = makeHandler().handle(
            request("POST", "/switch", body: #"{"monitor":"M27Q","target":"ghost"}"#))
        XCTAssertEqual(missing.status, 422)
        XCTAssertTrue(bodyJSON(missing)["error"]!.contains("deskswitch probe"))
    }

    func testBadJSONAndUnknownRoute() {
        XCTAssertEqual(makeHandler().handle(request("POST", "/switch", body: "not json")).status, 400)
        XCTAssertEqual(makeHandler().handle(request("GET", "/nope")).status, 404)
    }

    func testSwitchRequestDecodingDefaultsForwardedFalse() throws {
        let sw = try JSONDecoder().decode(SwitchRequest.self,
                                          from: Data(#"{"monitor":"M27Q","target":"x"}"#.utf8))
        XCTAssertFalse(sw.forwarded)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter APIHandlerTests`
Expected: compile error — `APIHandler` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/APIHandler.swift`:

```swift
import Foundation

public struct SwitchRequest: Codable, Equatable {
    public var monitor: String
    public var target: String
    public var forwarded: Bool

    public init(monitor: String, target: String, forwarded: Bool = false) {
        self.monitor = monitor
        self.target = target
        self.forwarded = forwarded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitor = try c.decode(String.self, forKey: .monitor)
        target = try c.decode(String.self, forKey: .target)
        forwarded = try c.decodeIfPresent(Bool.self, forKey: .forwarded) ?? false
    }
}

public struct APIHandler {
    private let router: Router
    private let token: String

    public init(router: Router, token: String) {
        self.router = router
        self.token = token
    }

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard req.headers["x-deskswitch-token"] == token else {
            return .json(401, ["error": "missing or invalid X-DeskSwitch-Token header"])
        }
        switch (req.method, req.path) {
        case ("GET", "/status"):
            return .json(200, router.localStatus())
        case ("POST", "/switch"):
            guard let sw = try? JSONDecoder().decode(SwitchRequest.self, from: req.body) else {
                return .json(400, ["error": #"body must be {"monitor": "<name>", "target": "<machine>"}"#])
            }
            do {
                let outcome = try router.switchMonitor(sw.monitor, to: sw.target,
                                                       allowForward: !sw.forwarded)
                return .json(200, ["outcome": outcome == .switchedLocally ? "switched-locally" : "forwarded"])
            } catch let e as RouterError {
                return .json(Self.status(for: e), ["error": e.userMessage])
            } catch {
                return .json(500, ["error": "\(error)"])
            }
        default:
            return .json(404, ["error": "not found"])
        }
    }

    public static func status(for error: RouterError) -> Int {
        switch error {
        case .unknownMonitor: return 404
        case .missingInputCode: return 422
        case .nobodyDrives: return 409
        case .peerUnreachable: return 502
        case .ddcFailure: return 500
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter APIHandlerTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/APIHandler.swift Tests/DeskSwitchCoreTests/APIHandlerTests.swift
git commit -m "feat: HTTP API handler with token auth and router error mapping"
```

---

### Task 10: HTTP server on Network.framework

**Files:**
- Create: `Sources/DeskSwitchCore/HTTPServer.swift`
- Test: `Tests/DeskSwitchCoreTests/HTTPServerTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest.parse`, `HTTPResponse.serialized` (Task 8).
- Produces: `HTTPServer` with `init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) throws`, `start()`, `stop()`. Used by serve command (Task 12) and app bootstrap (Task 14).

- [ ] **Step 1: Write the failing test (loopback integration — no hardware needed)**

`Tests/DeskSwitchCoreTests/HTTPServerTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class HTTPServerTests: XCTestCase {
    func testServesHandlerResponseOverLoopback() throws {
        let port: UInt16 = 18377
        let server = try HTTPServer(port: port) { req in
            .json(200, ["echo": req.path])
        }
        server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/hello")!
        let expectation = expectation(description: "response")
        var received: (Int, [String: String])?
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, let data,
               let json = try? JSONDecoder().decode([String: String].self, from: data) {
                received = (http.statusCode, json)
            }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(received?.0, 200)
        XCTAssertEqual(received?.1, ["echo": "/hello"])
    }

    func testMalformedRequestGets400() throws {
        let port: UInt16 = 18378
        let server = try HTTPServer(port: port) { _ in .json(200, ["ok": "1"]) }
        server.start()
        defer { server.stop() }

        // Raw socket write of garbage, expect an HTTP 400 status line back.
        let expectation = expectation(description: "raw response")
        let conn = TCPTestClient(host: "127.0.0.1", port: port)
        conn.sendAndReadAll(Data("NONSENSE\r\n\r\n".utf8)) { data in
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 400"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}
```

Add the raw TCP helper at the bottom of `Tests/DeskSwitchCoreTests/HTTPServerTests.swift`:

```swift
import Network

/// Minimal raw TCP client for exercising the server with non-HTTP bytes.
final class TCPTestClient {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func sendAndReadAll(_ data: Data, completion: @escaping (Data) -> Void) {
        connection.start(queue: .global())
        connection.send(content: data, completion: .contentProcessed { _ in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                completion(data ?? Data())
                self.connection.cancel()
            }
        })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HTTPServerTests`
Expected: compile error — `HTTPServer` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/HTTPServer.swift`:

```swift
import Foundation
import Network

/// Minimal HTTP/1.1 server: one request per connection, Connection: close semantics.
/// Bound to the LAN; auth is the caller-supplied handler's job (APIHandler).
public final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "deskswitch.http")

    public init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            switch HTTPRequest.parse(accumulated) {
            case .request(let request):
                self.respond(connection, with: self.handler(request))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: accumulated)
                }
            case .invalid:
                self.respond(connection, with: .json(400, ["error": "malformed request"]))
            }
        }
    }

    private func respond(_ connection: NWConnection, with response: HTTPResponse) {
        connection.send(content: response.serialized(),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HTTPServerTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/HTTPServer.swift Tests/DeskSwitchCoreTests/HTTPServerTests.swift
git commit -m "feat: NWListener-based HTTP server"
```

---

### Task 11: HTTP peer client

**Files:**
- Create: `Sources/DeskSwitchCore/HTTPPeerClient.swift`
- Test: `Tests/DeskSwitchCoreTests/HTTPPeerClientTests.swift`

**Interfaces:**
- Consumes: `PeerClient`/`PeerClientError` (Task 5), `SwitchRequest` (Task 9), `LocalStatus` (Task 5), `HTTPServer` (Task 10, for loopback tests).
- Produces: `HTTPPeerClient(host:port:token:)` conforming to `PeerClient`; 2-second request timeout; sends `X-DeskSwitch-Token`; maps transport errors to `.unreachable`, non-2xx to `.remote(status:message:)`.

- [ ] **Step 1: Write the failing tests (loopback against HTTPServer)**

`Tests/DeskSwitchCoreTests/HTTPPeerClientTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class HTTPPeerClientTests: XCTestCase {
    func serve(port: UInt16, _ handler: @escaping (HTTPRequest) -> HTTPResponse) throws -> HTTPServer {
        let server = try HTTPServer(port: port, handler: handler)
        server.start()
        return server
    }

    func testStatusDecodesAndSendsToken() throws {
        var seenToken: String?
        let server = try serve(port: 18380) { req in
            seenToken = req.headers["x-deskswitch-token"]
            return .json(200, LocalStatus(machine: "macbook", monitors: [
                MonitorStatus(name: "PA278CV", inputCode: 17, owner: "macbook"),
            ]))
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18380, token: "secret")
        let status = try client.status()
        XCTAssertEqual(status.machine, "macbook")
        XCTAssertEqual(status.monitors.first?.name, "PA278CV")
        XCTAssertEqual(seenToken, "secret")
    }

    func testRequestSwitchPostsForwardedBody() throws {
        var seen: SwitchRequest?
        let server = try serve(port: 18381) { req in
            seen = try? JSONDecoder().decode(SwitchRequest.self, from: req.body)
            return .json(200, ["outcome": "switched-locally"])
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18381, token: "secret")
        try client.requestSwitch(monitor: "M27Q", target: "macmini", forwarded: true)
        XCTAssertEqual(seen, SwitchRequest(monitor: "M27Q", target: "macmini", forwarded: true))
    }

    func testRemoteErrorCarriesStatusAndMessage() throws {
        let server = try serve(port: 18382) { _ in
            .json(409, ["error": "no machine currently drives 'M27Q'"])
        }
        defer { server.stop() }

        let client = HTTPPeerClient(host: "127.0.0.1", port: 18382, token: "secret")
        XCTAssertThrowsError(try client.requestSwitch(monitor: "M27Q", target: "x", forwarded: false)) {
            XCTAssertEqual($0 as? PeerClientError,
                           .remote(status: 409, message: "no machine currently drives 'M27Q'"))
        }
    }

    func testUnreachableHostThrowsUnreachableWithinBudget() {
        // Nothing listens on this port.
        let client = HTTPPeerClient(host: "127.0.0.1", port: 18399, token: "secret")
        let start = Date()
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError, .unreachable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0)  // 2 s budget + slack
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HTTPPeerClientTests`
Expected: compile error — `HTTPPeerClient` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/HTTPPeerClient.swift`:

```swift
import Foundation

public final class HTTPPeerClient: PeerClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(host: String, port: Int, token: String) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.0   // spec: 2 s budget per hop
        configuration.timeoutIntervalForResource = 2.0
        self.session = URLSession(configuration: configuration)
    }

    public func status() throws -> LocalStatus {
        let data = try send(path: "/status", method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(LocalStatus.self, from: data)
        } catch {
            throw PeerClientError.remote(status: 200, message: "undecodable status payload")
        }
    }

    public func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        let body = try? JSONEncoder().encode(
            SwitchRequest(monitor: monitor, target: target, forwarded: forwarded))
        _ = try send(path: "/switch", method: "POST", body: body)
    }

    private func send(path: String, method: String, body: Data?) throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue(token, forHTTPHeaderField: "X-DeskSwitch-Token")

        let semaphore = DispatchSemaphore(value: 0)
        var result: (data: Data?, response: URLResponse?, error: Error?)
        session.dataTask(with: request) {
            result = ($0, $1, $2)
            semaphore.signal()
        }.resume()
        semaphore.wait()

        guard result.error == nil,
              let http = result.response as? HTTPURLResponse,
              let data = result.data else {
            throw PeerClientError.unreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? "peer returned \(http.statusCode)"
            throw PeerClientError.remote(status: http.statusCode, message: message)
        }
        return data
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HTTPPeerClientTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/HTTPPeerClient.swift Tests/DeskSwitchCoreTests/HTTPPeerClientTests.swift
git commit -m "feat: URLSession peer client with 2s timeout and token auth"
```

---

### Task 12: `serve` command, real peer wiring, E2E script + M2 checklist

**Files:**
- Modify: `Sources/deskswitch/CLI.swift` (swap `makePeerClient`, add `Serve` subcommand)
- Create: `scripts/e2e.sh`, `docs/verification/m2-checklist.md`

**Interfaces:**
- Consumes: `HTTPServer` (Task 10), `HTTPPeerClient` (Task 11), `APIHandler` (Task 9).
- Produces: `deskswitch serve` runs the HTTP agent; `makePeerClient(config:)` now returns `HTTPPeerClient` (Task 16 wraps it in `WakingPeerClient`).

- [ ] **Step 1: Swap the peer client factory**

In `Sources/deskswitch/CLI.swift`, replace the `makePeerClient` function body:

```swift
/// Peer client factory. (Task 16 wraps this in WakingPeerClient for WoL retry.)
func makePeerClient(config: Config) -> PeerClient {
    HTTPPeerClient(host: config.peer.host, port: config.peer.port, token: config.token)
}
```

- [ ] **Step 2: Add the Serve subcommand**

In `Sources/deskswitch/CLI.swift`, add `Serve.self` to the `subcommands:` array of `DeskSwitchCLI`, then append:

```swift
struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the HTTP agent (headless mode).")

    func run() throws {
        let config = loadValidatedConfig()
        let router = makeRouter(config: config)
        let handler = APIHandler(router: router, token: config.token)
        let server = try HTTPServer(port: UInt16(config.listenPort)) { handler.handle($0) }
        server.start()
        print("deskswitch \(deskswitchVersion) serving on port \(config.listenPort) as '\(config.machineName)'")
        RunLoop.main.run()  // Task 20 adds the SleepGuard timer here
    }
}
```

- [ ] **Step 3: Verify build and tests**

Run: `swift test && swift build`
Expected: all PASS.

Smoke test locally (single machine):

```bash
swift run deskswitch serve &
sleep 2
curl -s -H "X-DeskSwitch-Token: $(python3 -c "import json;print(json.load(open('$HOME/.config/deskswitch/config.json'))['token'])")" http://127.0.0.1:8377/status
kill %1
```

Expected: JSON like `{"machine":"macmini","monitors":[...]}`.

- [ ] **Step 4: Write the E2E script**

`scripts/e2e.sh`:

```bash
#!/bin/bash
# End-to-end verification: run from either Mac with BOTH agents serving.
# Usage: TOKEN=<shared-secret> [MINI=host:port] [MBP=host:port] scripts/e2e.sh
set -euo pipefail

MINI="${MINI:-macmini.local:8377}"
MBP="${MBP:-macbook.local:8377}"
TOKEN="${TOKEN:?set TOKEN to the shared secret}"
AUTH="X-DeskSwitch-Token: $TOKEN"

step() { printf '\n== %s\n' "$*"; }
post() { curl -sf -m 5 -H "$AUTH" -H 'Content-Type: application/json' -d "$2" "http://$1/switch"; echo; }
status() { curl -sf -m 5 -H "$AUTH" "http://$1/status"; echo; }

step "status: both agents answer"
status "$MINI"
status "$MBP"

step "push/pull both monitors to macmini (router forwards if needed)"
post "$MINI" '{"monitor":"M27Q","target":"macmini"}'
post "$MINI" '{"monitor":"PA278CV","target":"macmini"}'

step "pull both monitors to macbook via the mini (forward path)"
post "$MINI" '{"monitor":"M27Q","target":"macbook"}'
post "$MINI" '{"monitor":"PA278CV","target":"macbook"}'

step "flip both back to macmini via the macbook agent"
post "$MBP" '{"monitor":"M27Q","target":"macmini"}'
post "$MBP" '{"monitor":"PA278CV","target":"macmini"}'

step "bad token is rejected with 401"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-DeskSwitch-Token: wrong" "http://$MINI/status")
[ "$code" = "401" ] && echo "OK (401)" || { echo "FAIL: got $code"; exit 1; }

step "unknown monitor is rejected with 404"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" -H 'Content-Type: application/json' \
    -d '{"monitor":"LG99","target":"macmini"}' "http://$MINI/switch")
[ "$code" = "404" ] && echo "OK (404)" || { echo "FAIL: got $code"; exit 1; }

echo
echo "E2E complete — verify visually that both monitors ended on macmini."
```

Run: `chmod +x scripts/e2e.sh`

- [ ] **Step 5: Write the M2 checklist**

`docs/verification/m2-checklist.md`:

```markdown
# M2 Verification — HTTP API + router

Prerequisite: M1 checklist passed on both Macs; both configs hold full input maps;
`deskswitch serve` (or `swift run deskswitch serve`) running on BOTH Macs.

- [ ] `TOKEN=<secret> scripts/e2e.sh` passes end to end from the Mac mini
- [ ] `TOKEN=<secret> scripts/e2e.sh` passes end to end from the MacBook
- [ ] Pull flow works from the CLI: `deskswitch switch M27Q <this-machine>` on the Mac
      that does NOT drive M27Q prints `forwarded to peer` and the monitor appears here
- [ ] Stop the peer agent, run `deskswitch switch <monitor-driven-by-peer> <this-machine>`:
      fails with `other Mac offline` in ~2-4 s (2 s budget/hop; WoL retry arrives in M4)
- [ ] `deskswitch status` shows both machines' monitors when both agents run
- [ ] Topology refresh: with both agents left RUNNING (no restarts), push a monitor away
      and pull it back; `status` on both Macs reflects each move, and the pull succeeds on
      the Mac that started headless (the engine re-enumerates displays per operation)
- [ ] iPhone Shortcut (optional preview): "Get Contents of URL" POST to
      http://macmini.local:8377/switch with the token header flips a monitor
```

- [ ] **Step 6: Commit**

```bash
git add Sources/deskswitch/CLI.swift scripts/e2e.sh docs/verification/m2-checklist.md
git commit -m "feat: serve command with real peer forwarding, E2E script (M2 complete)"
```

---

### Task 13: Menu view model — rows, refresh, actions

**Files:**
- Create: `Sources/DeskSwitchCore/MenuState.swift`, `Sources/DeskSwitchCore/Notifier.swift`
- Test: `Tests/DeskSwitchCoreTests/MenuStateTests.swift`

**Interfaces:**
- Consumes: `Config`, `Router`, `PeerClient`, `LocalStatus`, `RouterError.userMessage`.
- Produces:
  - `Notifier` protocol (`notify(title:body:)`), `StderrNotifier`.
  - `MonitorRow: Equatable, Identifiable` (`name: String`, `owner: String?`; `id == name`).
  - `buildRows(config:localStatus:peerStatus:) -> [MonitorRow]`.
  - `MenuState: ObservableObject` — `init(config:router:peer:notifier:runAsync:publish:)` with injected executors: `runAsync` runs work off the main thread (default: global queue) and `publish` hops state mutations back (default: main queue); tests pass `{ $0() }` for both to stay synchronous. `@Published rows: [MonitorRow]`, `@Published lastError: String?`, methods `refresh()` and `send(_:to:)` — every UI entry point dispatches through `runAsync` immediately, so menu-open and button actions NEVER block the main thread on network/DDC/WoL (spec rule); Task 18 adds `bringAllHere()`/`sendAllAway()` on the same pattern.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/MenuStateTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class MockNotifier: Notifier {
    var messages: [(title: String, body: String)] = []
    func notify(title: String, body: String) {
        messages.append((title, body))
    }
}

final class MenuStateTests: XCTestCase {
    var ddc = MockDDCEngine()
    var peer = MockPeerClient()
    var notifier = MockNotifier()

    /// Synchronous executors make the async-by-default view model deterministic in tests.
    func makeState() -> MenuState {
        let config = testConfig()
        return MenuState(config: config,
                         router: Router(config: config, ddc: ddc, peer: peer),
                         peer: peer, notifier: notifier,
                         runAsync: { $0() }, publish: { $0() })
    }

    func testBuildRowsResolvesOwners() {
        let config = testConfig()
        let local = LocalStatus(machine: "macmini", monitors: [
            MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini"),
        ])
        let peerStatus = LocalStatus(machine: "macbook", monitors: [
            MonitorStatus(name: "PA278CV", inputCode: 17, owner: "macbook"),
        ])
        XCTAssertEqual(buildRows(config: config, localStatus: local, peerStatus: peerStatus), [
            MonitorRow(name: "M27Q", owner: "macmini"),
            MonitorRow(name: "PA278CV", owner: "macbook"),
        ])
    }

    func testBuildRowsUnknownOwnerWhenPeerDown() {
        let config = testConfig()
        let local = LocalStatus(machine: "macmini", monitors: [
            MonitorStatus(name: "M27Q", inputCode: 15, owner: "macmini"),
        ])
        XCTAssertEqual(buildRows(config: config, localStatus: local, peerStatus: nil), [
            MonitorRow(name: "M27Q", owner: "macmini"),
            MonitorRow(name: "PA278CV", owner: nil),
        ])
    }

    func testRefreshPopulatesRowsAndPeerError() {
        ddc.names = ["M27Q"]
        ddc.inputs = ["M27Q": 15]
        peer.statusResult = .failure(.unreachable)
        let state = makeState()
        state.refresh()
        XCTAssertEqual(state.rows.map(\.name), ["M27Q", "PA278CV"])
        XCTAssertEqual(state.lastError, "macbook unreachable")

        peer.statusResult = .success(LocalStatus(machine: "macbook", monitors: []))
        state.refresh()
        XCTAssertNil(state.lastError)
    }

    func testSendSuccessRefreshes() {
        ddc.names = ["M27Q"]
        ddc.inputs = ["M27Q": 15]
        let state = makeState()
        state.send("M27Q", to: "macbook")
        XCTAssertTrue(notifier.messages.isEmpty)
        XCTAssertEqual(ddc.setCalls.first?.code, 27)
    }

    func testSendFailureSetsErrorAndNotifies() {
        ddc.names = []
        peer.switchError = .unreachable
        let state = makeState()
        state.send("M27Q", to: "macmini")
        XCTAssertEqual(state.lastError, "other Mac offline")
        XCTAssertEqual(notifier.messages.count, 1)
        XCTAssertEqual(notifier.messages[0].body, "other Mac offline")
    }

    func testUIEntryPointsDispatchThroughAsyncExecutor() {
        // Locks in the spec's "UI never blocks on network" contract: every public
        // action must route through runAsync, never run inline on the caller thread.
        var dispatched = 0
        let config = testConfig()
        let state = MenuState(config: config,
                              router: Router(config: config, ddc: ddc, peer: peer),
                              peer: peer, notifier: notifier,
                              runAsync: { work in dispatched += 1; work() },
                              publish: { $0() })
        state.refresh()
        state.send("M27Q", to: "macbook")
        XCTAssertEqual(dispatched, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuStateTests`
Expected: compile error — `MenuState`, `Notifier` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/Notifier.swift`:

```swift
import Foundation

public protocol Notifier {
    func notify(title: String, body: String)
}

/// Fallback notifier for CLI/serve contexts where UNUserNotificationCenter
/// is unavailable (requires an app bundle).
public struct StderrNotifier: Notifier {
    public init() {}
    public func notify(title: String, body: String) {
        FileHandle.standardError.write(Data("[\(title)] \(body)\n".utf8))
    }
}
```

`Sources/DeskSwitchCore/MenuState.swift`:

```swift
import Combine
import Foundation

public struct MonitorRow: Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let owner: String?
    public init(name: String, owner: String?) {
        self.name = name
        self.owner = owner
    }
}

/// Resolves each configured monitor's owner: this machine if it drives it,
/// the peer if the peer reports it, else unknown (nil).
public func buildRows(config: Config, localStatus: LocalStatus,
                      peerStatus: LocalStatus?) -> [MonitorRow] {
    config.monitors.keys.sorted().map { name in
        let owner: String?
        if localStatus.monitors.contains(where: { $0.name == name }) {
            owner = config.machineName
        } else if peerStatus?.monitors.contains(where: { $0.name == name }) == true {
            owner = config.peer.name
        } else {
            owner = nil
        }
        return MonitorRow(name: name, owner: owner)
    }
}

public final class MenuState: ObservableObject {
    @Published public private(set) var rows: [MonitorRow] = []
    @Published public private(set) var lastError: String?

    private let config: Config
    private let router: Router
    private let peer: PeerClient
    private let notifier: Notifier
    private let runAsync: (@escaping () -> Void) -> Void
    private let publish: (@escaping () -> Void) -> Void

    /// Spec rule: the UI never blocks the main thread on network. Every public action
    /// dispatches its work through `runAsync` (default: background queue) and hops
    /// published-state mutations back through `publish` (default: main queue). Tests
    /// inject `{ $0() }` for both to run fully synchronously.
    public init(config: Config, router: Router, peer: PeerClient, notifier: Notifier,
                runAsync: @escaping (@escaping () -> Void) -> Void =
                    { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
                publish: @escaping (@escaping () -> Void) -> Void =
                    { DispatchQueue.main.async(execute: $0) }) {
        self.config = config
        self.router = router
        self.peer = peer
        self.notifier = notifier
        self.runAsync = runAsync
        self.publish = publish
    }

    /// Spec: refresh happens when the menu opens; no background polling.
    public func refresh() {
        runAsync { [weak self] in self?.performRefresh() }
    }

    public func send(_ monitor: String, to machine: String) {
        runAsync { [weak self] in self?.performSend(monitor, to: machine) }
    }

    /// Local DDC read + one peer status call (2 s budget) — always off-main via runAsync.
    private func performRefresh() {
        let local = router.localStatus()
        let peerStatus = try? peer.status()
        let rows = buildRows(config: config, localStatus: local, peerStatus: peerStatus)
        let error = peerStatus == nil ? "\(config.peer.name) unreachable" : nil
        publish { [weak self] in
            self?.rows = rows
            self?.lastError = error
        }
    }

    private func performSend(_ monitor: String, to machine: String) {
        do {
            _ = try router.switchMonitor(monitor, to: machine)
            performRefresh()
        } catch {
            let message = (error as? RouterError)?.userMessage ?? "\(error)"
            publish { [weak self] in self?.lastError = message }
            notifier.notify(title: "deskswitch", body: message)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MenuStateTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DeskSwitchCore/MenuState.swift Sources/DeskSwitchCore/Notifier.swift \
        Tests/DeskSwitchCoreTests/MenuStateTests.swift
git commit -m "feat: menu view model with owner resolution and failure notification"
```

---

### Task 14: SwiftUI menu bar app + entry-point dispatch

**Files:**
- Create: `Sources/deskswitch/App.swift`
- Modify: `Sources/deskswitch/main.swift`

**Interfaces:**
- Consumes: `MenuState`, `buildRows` (Task 13), `HTTPServer`+`APIHandler` (Tasks 9-10), `HTTPPeerClient` (Task 11), `IOAVDDCEngine` (Task 6), `Config`.
- Produces: `DeskSwitchApp: App` (MenuBarExtra) and `Bootstrap.make()`; `main.swift` dispatches bundle-launch → app, otherwise → CLI. The menu bar app ALSO runs the HTTP agent (a Mac must accept pull requests while the UI is up).

UI layers aren't unit-tested; correctness lives in `MenuState` (Task 13). Verification is the M3 checklist (Task 15).

- [ ] **Step 1: Write the app**

`Sources/deskswitch/App.swift`:

```swift
import AppKit
import DeskSwitchCore
import SwiftUI

/// Builds the full object graph for app mode. Failure produces an error the
/// menu can display instead of crashing at launch.
enum Bootstrap {
    static func make() -> Result<(MenuState, HTTPServer, Config), String> {
        do {
            let config = try Config.load()
            let issues = config.validate()
            if let firstError = issues.first(where: { $0.isError }) {
                return .failure(firstError.message)
            }
            for warning in issues where !warning.isError {
                FileHandle.standardError.write(Data(("config: " + warning.message + "\n").utf8))
            }
            let engine = try IOAVDDCEngine()
            let peer = makePeerClient(config: config)
            let router = Router(config: config, ddc: engine, peer: peer)
            let handler = APIHandler(router: router, token: config.token)
            let server = try HTTPServer(port: UInt16(config.listenPort)) { handler.handle($0) }
            server.start()
            // Task 17 replaces StderrNotifier with UserNotifier here.
            let state = MenuState(config: config, router: router, peer: peer,
                                  notifier: StderrNotifier())
            return .success((state, server, config))
        } catch {
            return .failure("\(error)")
        }
    }
}

struct DeskSwitchApp: App {
    private let boot = Bootstrap.make()

    var body: some Scene {
        MenuBarExtra("DeskSwitch", systemImage: "display.2") {
            switch boot {
            case .success(let (state, _, config)):
                MenuContent(state: state,
                            machineName: config.machineName,
                            peerName: config.peer.name)
            case .failure(let message):
                Text("deskswitch failed to start")
                Text(message)
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var state: MenuState
    let machineName: String
    let peerName: String

    var body: some View {
        Group {
            ForEach(state.rows) { row in
                if row.owner == machineName {
                    Button("\(row.name): here — send to \(peerName)") {
                        state.send(row.name, to: peerName)
                    }
                } else if row.owner == peerName {
                    Button("\(row.name): on \(peerName) — bring here") {
                        state.send(row.name, to: machineName)
                    }
                } else {
                    Text("\(row.name): unknown")
                }
            }
            // Task 18 adds "Bring both here" / "Send both away" actions here.
            if let error = state.lastError {
                Divider()
                Text(error)
            }
            Divider()
            Button("Quit deskswitch") { NSApp.terminate(nil) }
        }
        .onAppear { state.refresh() }  // spec: refresh when menu opens; MenuState
                                       // dispatches off-main internally, as do the
                                       // button actions above — no main-thread network
    }
}
```

- [ ] **Step 2: Wire the entry point**

Replace `Sources/deskswitch/main.swift`:

```swift
import Foundation

// App-bundle launch with no arguments (Finder, login item) → menu bar app.
// Anything else (terminal, swift run, explicit subcommand) → CLI.
if CommandLine.arguments.count <= 1 && Bundle.main.bundlePath.hasSuffix(".app") {
    DeskSwitchApp.main()
} else {
    DeskSwitchCLI.main()
}
```

- [ ] **Step 3: Verify build and tests**

Run: `swift test && swift build`
Expected: all PASS; build succeeds.

Run: `swift run deskswitch --help`
Expected: still prints CLI usage (terminal launch must not open UI).

- [ ] **Step 4: Commit**

```bash
git add Sources/deskswitch/App.swift Sources/deskswitch/main.swift
git commit -m "feat: SwiftUI menu bar app with embedded HTTP agent"
```

---

### Task 15: App bundle packaging + M3 checklist

**Files:**
- Create: `packaging/Info.plist`, `scripts/make-app.sh`, `docs/verification/m3-checklist.md`

**Interfaces:**
- Consumes: the `deskswitch` release binary.
- Produces: `scripts/make-app.sh` → `build/DeskSwitch.app` (LSUIElement, ad-hoc signed). Task 19 adds the LaunchAgent plist into this bundle.

- [ ] **Step 1: Write the Info.plist**

`packaging/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.vuphan.deskswitch</string>
    <key>CFBundleName</key><string>DeskSwitch</string>
    <key>CFBundleExecutable</key><string>deskswitch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the bundling script**

`scripts/make-app.sh`:

```bash
#!/bin/bash
# Builds build/DeskSwitch.app from the release binary. Ad-hoc signed (home use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/DeskSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/deskswitch "$APP/Contents/MacOS/deskswitch"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Task 19 adds: mkdir -p "$APP/Contents/Library/LaunchAgents" + LaunchAgent plist copy
codesign --force --sign - "$APP"
echo "Built $APP — copy to /Applications on both Macs"
```

Run: `chmod +x scripts/make-app.sh && scripts/make-app.sh`
Expected: `Built build/DeskSwitch.app ...`.

- [ ] **Step 3: Write the M3 checklist**

`docs/verification/m3-checklist.md`:

```markdown
# M3 Verification — Menu bar UI

Prerequisite: M2 checklist passed. Build with `scripts/make-app.sh`, copy
`build/DeskSwitch.app` to /Applications on both Macs, launch on both.

- [ ] Menu bar shows the display icon; NO Dock icon appears (LSUIElement)
- [ ] Opening the menu shows one row per configured monitor with correct owner
      ("here" vs peer name) — refreshed on open, spec: no background polling
- [ ] Row action on a locally-driven monitor pushes it away; monitor flips, menu row
      updates on next open
- [ ] Row action on a peer-driven monitor pulls it here (forward path through peer agent)
- [ ] With the peer app quit, menu shows "<peer> unreachable" and pull actions surface
      "other Mac offline" without hanging the UI (2 s budget, background refresh)
- [ ] The embedded HTTP agent works: e2e.sh passes while only the .app (no `serve`) runs
- [ ] `deskswitch status` from the terminal still works while the app runs
      (CLI dispatch unaffected)
```

- [ ] **Step 4: Commit**

```bash
git add packaging/Info.plist scripts/make-app.sh docs/verification/m3-checklist.md
git commit -m "feat: app bundle packaging with LSUIElement (M3 complete)"
```

---

### Task 16: Wake-on-LAN — magic packet, UDP sender, waking peer client

**Files:**
- Create: `Sources/DeskSwitchCore/WoL.swift`
- Modify: `Sources/deskswitch/CLI.swift` (`makePeerClient`), `Sources/deskswitch/App.swift` (no change needed — it calls `makePeerClient`)
- Test: `Tests/DeskSwitchCoreTests/WoLTests.swift`

**Interfaces:**
- Consumes: `Config` (`peer.mac`, `wol.broadcastHost`, `wol.port`), `PeerClient`/`PeerClientError`.
- Produces:
  - `wolMagicPacket(mac: String) throws -> Data`; `WoLError.invalidMAC(String)`.
  - `WoLSender` protocol (`wake() throws`); `UDPWoLSender(packet:host:port:)`.
  - `WakingPeerClient(inner:wol:wakeDelay:retryDelay:sleeper:)` conforming to `PeerClient` — on `.unreachable`: send WoL when a sender is configured, wait `wakeDelay`, retry once; without a `wol` sender (missing `peer.mac`) the magic packet is SKIPPED but the single retry still happens after the shorter `retryDelay` (spec: degrade to retry + notification — the retry is not conditional on WoL).
  - `makeWoLSender(config: Config) -> WoLSender?` helper.

- [ ] **Step 1: Write the failing tests**

`Tests/DeskSwitchCoreTests/WoLTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class MockWoLSender: WoLSender {
    var wakeCount = 0
    func wake() throws { wakeCount += 1 }
}

/// Peer that fails with .unreachable a set number of times, then succeeds.
final class FlakyPeerClient: PeerClient {
    var failuresRemaining: Int
    var calls = 0
    init(failures: Int) { self.failuresRemaining = failures }

    private func gate() throws {
        calls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PeerClientError.unreachable
        }
    }

    func status() throws -> LocalStatus {
        try gate()
        return LocalStatus(machine: "macbook", monitors: [])
    }

    func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        try gate()
    }
}

final class WoLTests: XCTestCase {
    func testMagicPacketLayout() throws {
        let packet = try wolMagicPacket(mac: "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for i in 0..<16 {
            XCTAssertEqual(Array(packet[(6 + i * 6)..<(6 + (i + 1) * 6)]), mac, "repeat \(i)")
        }
    }

    func testMagicPacketAcceptsDashesAndRejectsGarbage() throws {
        XCTAssertEqual(try wolMagicPacket(mac: "AA-BB-CC-DD-EE-FF"),
                       try wolMagicPacket(mac: "aa:bb:cc:dd:ee:ff"))
        XCTAssertThrowsError(try wolMagicPacket(mac: "not-a-mac"))
        XCTAssertThrowsError(try wolMagicPacket(mac: "aa:bb:cc:dd:ee"))
    }

    func testWakingClientSendsWoLAndRetriesOnce() throws {
        let flaky = FlakyPeerClient(failures: 1)
        let wol = MockWoLSender()
        let client = WakingPeerClient(inner: flaky, wol: wol, wakeDelay: 0, sleeper: { _ in })
        try client.requestSwitch(monitor: "M27Q", target: "macmini", forwarded: false)
        XCTAssertEqual(wol.wakeCount, 1)
        XCTAssertEqual(flaky.calls, 2)
    }

    func testWakingClientGivesUpAfterOneRetry() {
        let flaky = FlakyPeerClient(failures: 2)
        let wol = MockWoLSender()
        let client = WakingPeerClient(inner: flaky, wol: wol, wakeDelay: 0, sleeper: { _ in })
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError, .unreachable)
        }
        XCTAssertEqual(wol.wakeCount, 1)
        XCTAssertEqual(flaky.calls, 2)
    }

    func testWithoutWoLSenderStillRetriesOnceWithoutWaking() throws {
        // Spec degrade path (config prose + error table): peer.mac unset → skip the
        // magic packet, but the single retry before "other Mac offline" remains.
        let recovers = FlakyPeerClient(failures: 1)
        let client = WakingPeerClient(inner: recovers, wol: nil, wakeDelay: 0, sleeper: { _ in })
        XCTAssertNoThrow(try client.status())
        XCTAssertEqual(recovers.calls, 2)

        let dead = FlakyPeerClient(failures: 2)
        let deadClient = WakingPeerClient(inner: dead, wol: nil, wakeDelay: 0, sleeper: { _ in })
        XCTAssertThrowsError(try deadClient.status()) {
            XCTAssertEqual($0 as? PeerClientError, .unreachable)
        }
        XCTAssertEqual(dead.calls, 2)
    }

    func testNonUnreachableErrorsPassThroughWithoutWoL() {
        final class RemoteErrorPeer: PeerClient {
            func status() throws -> LocalStatus {
                throw PeerClientError.remote(status: 409, message: "x")
            }
            func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
                throw PeerClientError.remote(status: 409, message: "x")
            }
        }
        let wol = MockWoLSender()
        let client = WakingPeerClient(inner: RemoteErrorPeer(), wol: wol, wakeDelay: 0, sleeper: { _ in })
        XCTAssertThrowsError(try client.status()) {
            XCTAssertEqual($0 as? PeerClientError, .remote(status: 409, message: "x"))
        }
        XCTAssertEqual(wol.wakeCount, 0)
    }

    func testMakeWoLSenderRespectsConfig() {
        XCTAssertNotNil(makeWoLSender(config: testConfig()))  // has peer.mac
        var noMac = testConfig()
        noMac.peer.mac = nil
        XCTAssertNil(makeWoLSender(config: noMac))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WoLTests`
Expected: compile error — `wolMagicPacket`, `WakingPeerClient` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/WoL.swift`:

```swift
import Foundation

public enum WoLError: Error, Equatable {
    case invalidMAC(String)
    case sendFailed(String)
}

/// Standard Wake-on-LAN magic packet: 6 x 0xFF then the MAC repeated 16 times.
public func wolMagicPacket(mac: String) throws -> Data {
    let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { throw WoLError.invalidMAC(mac) }
    let bytes: [UInt8] = try parts.map {
        guard $0.count == 2, let byte = UInt8($0, radix: 16) else {
            throw WoLError.invalidMAC(mac)
        }
        return byte
    }
    var packet = Data(repeating: 0xFF, count: 6)
    for _ in 0..<16 {
        packet.append(contentsOf: bytes)
    }
    return packet
}

public protocol WoLSender {
    func wake() throws
}

/// Sends the magic packet as a UDP broadcast (config: wol.broadcastHost / wol.port).
public struct UDPWoLSender: WoLSender {
    let packet: Data
    let host: String
    let port: UInt16

    public init(packet: Data, host: String, port: UInt16) {
        self.packet = packet
        self.host = host
        self.port = port
    }

    public func wake() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw WoLError.sendFailed("socket() failed") }
        defer { close(fd) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw WoLError.sendFailed("bad broadcast address \(host)")
        }

        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, packet.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            throw WoLError.sendFailed("sendto() sent \(sent) of \(packet.count) bytes")
        }
    }
}

/// Builds a sender from config; nil when peer.mac is unset (WoL degrades off — spec).
public func makeWoLSender(config: Config) -> WoLSender? {
    guard let mac = config.peer.mac, let packet = try? wolMagicPacket(mac: mac) else {
        return nil
    }
    return UDPWoLSender(packet: packet, host: config.wol.broadcastHost,
                        port: UInt16(config.wol.port))
}

/// Decorator implementing the spec's peer-unreachable behavior: send the WoL magic
/// packet when a sender is configured, wait for the peer to wake, then retry once.
/// When peer.mac is unset there is no sender — the magic packet is skipped but the
/// single retry still happens after a short delay (spec: degrade to retry + notification).
public final class WakingPeerClient: PeerClient {
    private let inner: PeerClient
    private let wol: WoLSender?
    private let wakeDelay: TimeInterval
    private let retryDelay: TimeInterval
    private let sleeper: (TimeInterval) -> Void

    public init(inner: PeerClient, wol: WoLSender?, wakeDelay: TimeInterval = 3.0,
                retryDelay: TimeInterval = 0.5,
                sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.inner = inner
        self.wol = wol
        self.wakeDelay = wakeDelay
        self.retryDelay = retryDelay
        self.sleeper = sleeper
    }

    public func status() throws -> LocalStatus {
        try retrying { try inner.status() }
    }

    public func requestSwitch(monitor: String, target: String, forwarded: Bool) throws {
        try retrying { try inner.requestSwitch(monitor: monitor, target: target, forwarded: forwarded) }
    }

    private func retrying<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch PeerClientError.unreachable {
            // Spec error table: send WoL (skipped when peer.mac is unset), then retry
            // once EITHER WAY; only the wait differs (wake cycle vs brief backoff).
            if let wol {
                try? wol.wake()
                sleeper(wakeDelay)
            } else {
                sleeper(retryDelay)
            }
            return try operation()
        }
    }
}
```

- [ ] **Step 4: Wire it into the peer client factory**

In `Sources/deskswitch/CLI.swift`, replace `makePeerClient`:

```swift
/// Peer client with WoL-and-retry on unreachable (degrades to plain errors
/// when peer.mac is unset — config validation already warned about that).
func makePeerClient(config: Config) -> PeerClient {
    let http = HTTPPeerClient(host: config.peer.host, port: config.peer.port, token: config.token)
    return WakingPeerClient(inner: http, wol: makeWoLSender(config: config))
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: all PASS (WoLTests adds 7).

- [ ] **Step 6: Commit**

```bash
git add Sources/DeskSwitchCore/WoL.swift Sources/deskswitch/CLI.swift \
        Tests/DeskSwitchCoreTests/WoLTests.swift
git commit -m "feat: Wake-on-LAN magic packet with retry-once peer client decorator"
```

---

### Task 17: macOS notifications

**Files:**
- Create: `Sources/deskswitch/UserNotifier.swift`
- Modify: `Sources/deskswitch/App.swift` (use `UserNotifier` in app mode)

**Interfaces:**
- Consumes: `Notifier` protocol (Task 13); `MenuState` already routes every switch failure through its notifier, so no call-site changes are needed.
- Produces: `UserNotifier: Notifier` posting real macOS notifications (app-bundle mode only; CLI/serve keep `StderrNotifier`).

- [ ] **Step 1: Write the notifier**

`Sources/deskswitch/UserNotifier.swift`:

```swift
import DeskSwitchCore
import UserNotifications

/// Real macOS notifications. Requires an app bundle (UNUserNotificationCenter
/// asserts without one), hence lives in the executable and is only used in app mode.
final class UserNotifier: Notifier {
    init() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
```

- [ ] **Step 2: Use it in app bootstrap**

In `Sources/deskswitch/App.swift`, inside `Bootstrap.make()`, replace the `MenuState` construction line:

```swift
            let state = MenuState(config: config, router: router, peer: peer,
                                  notifier: UserNotifier())
```

- [ ] **Step 3: Verify build and tests**

Run: `swift test && swift build`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/deskswitch/UserNotifier.swift Sources/deskswitch/App.swift
git commit -m "feat: macOS notifications for switch failures in app mode"
```

---

### Task 18: Flip-both convenience actions (UI + CLI)

**Files:**
- Modify: `Sources/DeskSwitchCore/MenuState.swift`, `Sources/deskswitch/App.swift`, `Sources/deskswitch/CLI.swift`
- Test: `Tests/DeskSwitchCoreTests/MenuStateTests.swift` (append)

**Interfaces:**
- Consumes: `Router.switchAll(to:)` (Task 5).
- Produces: `MenuState.bringAllHere()` / `MenuState.sendAllAway()`; menu buttons "Bring both here" / "Send both away"; CLI accepts `deskswitch switch all <machine>`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DeskSwitchCoreTests/MenuStateTests.swift`:

```swift
    func testBringAllHereSwitchesEveryMonitorTowardThisMachine() {
        ddc.names = ["M27Q", "PA278CV"]
        ddc.inputs = ["M27Q": 27, "PA278CV": 17]
        let state = makeState()
        state.bringAllHere()
        XCTAssertEqual(ddc.setCalls.map(\.code).sorted(), [15, 15])
        XCTAssertNil(state.lastError)
    }

    func testSendAllAwayReportsFirstFailure() {
        ddc.names = ["M27Q"]   // PA278CV not driven here…
        peer.switchError = .unreachable  // …and peer is down → its switch fails
        let state = makeState()
        state.sendAllAway()
        XCTAssertEqual(ddc.setCalls.map(\.code), [27])  // M27Q still pushed
        XCTAssertEqual(state.lastError, "PA278CV: other Mac offline")
        XCTAssertEqual(notifier.messages.count, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuStateTests`
Expected: FAIL — `bringAllHere` not defined (compile error).

- [ ] **Step 3: Implement the view-model actions**

Append to `MenuState` in `Sources/DeskSwitchCore/MenuState.swift`:

```swift
    public func bringAllHere() {
        runAsync { [weak self] in
            guard let self else { return }
            self.performSwitchAll(to: self.config.machineName)
        }
    }

    public func sendAllAway() {
        runAsync { [weak self] in
            guard let self else { return }
            self.performSwitchAll(to: self.config.peer.name)
        }
    }

    private func performSwitchAll(to target: String) {
        let failures = router.switchAll(to: target).compactMap { entry -> String? in
            guard case .failure(let error) = entry.result else { return nil }
            return "\(entry.monitor): \(error.userMessage)"
        }
        // performRefresh publishes lastError from peer reachability; the switch failure
        // (the more specific message) is published after it so it wins.
        performRefresh()
        if let first = failures.first {
            publish { [weak self] in self?.lastError = first }
            notifier.notify(title: "deskswitch", body: first)
        }
    }
```

(Both actions dispatch through `runAsync` like every other UI entry point — flip-both touches DDC, the peer, and possibly WoL wake delays, so it must never run on the main thread. With the tests' synchronous executors the ordering is deterministic: peer down → `performRefresh` publishes "macbook unreachable", then the per-monitor failure line overwrites it, matching `testSendAllAwayReportsFirstFailure`.)

- [ ] **Step 4: Add the menu buttons**

In `Sources/deskswitch/App.swift`, replace the `// Task 18 adds ...` comment inside `MenuContent` with:

```swift
            Divider()
            Button("Bring both here") { state.bringAllHere() }
            Button("Send both away") { state.sendAllAway() }
```

- [ ] **Step 5: Teach the CLI `switch all`**

In `Sources/deskswitch/CLI.swift`, replace the body of `Switch.run()`:

```swift
    func run() throws {
        let config = loadValidatedConfig()
        let router = makeRouter(config: config)
        if monitor == "all" {
            var failed = false
            for entry in router.switchAll(to: machine) {
                switch entry.result {
                case .success(let outcome):
                    print("\(entry.monitor): \(outcome == .switchedLocally ? "switched locally" : "forwarded to peer")")
                case .failure(let error):
                    failed = true
                    FileHandle.standardError.write(Data("\(entry.monitor): \(error.userMessage)\n".utf8))
                }
            }
            if failed { throw ExitCode(1) }
            return
        }
        do {
            let outcome = try router.switchMonitor(monitor, to: machine)
            print(outcome == .switchedLocally ? "switched locally" : "forwarded to peer")
        } catch let e as RouterError {
            fail(e.userMessage)
        }
    }
```

Also update the `@Argument` help text for `monitor`:

```swift
    @Argument(help: "Monitor name from config (e.g. M27Q), or 'all' for both monitors.")
    var monitor: String
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test && swift build`
Expected: all PASS (MenuStateTests now 8).

- [ ] **Step 7: Commit**

```bash
git add Sources/DeskSwitchCore/MenuState.swift Sources/deskswitch/App.swift \
        Sources/deskswitch/CLI.swift Tests/DeskSwitchCoreTests/MenuStateTests.swift
git commit -m "feat: flip-both convenience actions in menu and CLI"
```

---

### Task 19: Login item via SMAppService

**Files:**
- Create: `packaging/com.vuphan.deskswitch.plist`
- Modify: `scripts/make-app.sh`, `Sources/deskswitch/CLI.swift` (add `Autostart` subcommand)

**Interfaces:**
- Consumes: app bundle (Task 15).
- Produces: `deskswitch autostart enable|disable|status`; LaunchAgent embedded in the bundle with `RunAtLoad` + `KeepAlive` (starts at login, restarts on crash — spec Lifecycle).

- [ ] **Step 1: Write the LaunchAgent plist**

`packaging/com.vuphan.deskswitch.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.vuphan.deskswitch</string>
    <key>BundleProgram</key><string>Contents/MacOS/deskswitch</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
```

- [ ] **Step 2: Embed it in the bundle**

In `scripts/make-app.sh`, replace the `# Task 19 adds ...` comment line with:

```bash
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp packaging/com.vuphan.deskswitch.plist "$APP/Contents/Library/LaunchAgents/"
```

- [ ] **Step 3: Add the Autostart subcommand**

In `Sources/deskswitch/CLI.swift`, add `import ServiceManagement` at the top, add `Autostart.self` to the `subcommands:` array, and append:

```swift
struct Autostart: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage launch-at-login registration (run from inside DeskSwitch.app).")

    @Argument(help: "enable | disable | status")
    var action: String

    func run() throws {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            fail("autostart must be run via the installed bundle, e.g. " +
                 "/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart \(action)")
        }
        let service = SMAppService.agent(plistName: "com.vuphan.deskswitch.plist")
        switch action {
        case "enable":
            try service.register()
            print("registered (status: \(statusText(service.status)))")
        case "disable":
            try service.unregister()
            print("unregistered")
        case "status":
            print(statusText(service.status))
        default:
            fail("action must be enable, disable, or status")
        }
    }

    private func statusText(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings > General > Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}
```

- [ ] **Step 4: Verify build, tests, and bundle**

Run: `swift test && scripts/make-app.sh`
Expected: all PASS; bundle contains `Contents/Library/LaunchAgents/com.vuphan.deskswitch.plist` (verify with `ls build/DeskSwitch.app/Contents/Library/LaunchAgents/`).

- [ ] **Step 5: Commit**

```bash
git add packaging/com.vuphan.deskswitch.plist scripts/make-app.sh Sources/deskswitch/CLI.swift
git commit -m "feat: launch-at-login with crash restart via SMAppService LaunchAgent"
```

---

### Task 20: Headless sleep prevention + M4 checklist

**Files:**
- Create: `Sources/DeskSwitchCore/SleepGuard.swift`, `docs/verification/m4-checklist.md`
- Modify: `Sources/deskswitch/App.swift`, `Sources/deskswitch/CLI.swift` (`Serve`)
- Test: `Tests/DeskSwitchCoreTests/SleepGuardTests.swift`

**Interfaces:**
- Consumes: `Config.preventSleepWhenHeadless`, `Router.localStatus()`.
- Produces: `shouldHoldAssertion(headless:enabled:) -> Bool` (pure, tested); `SleepGuard` class (`update(headless:enabled:)`); `startSleepGuardTimer(config:router:) -> Timer` used by both app and serve modes.

- [ ] **Step 1: Write the failing test**

`Tests/DeskSwitchCoreTests/SleepGuardTests.swift`:

```swift
import XCTest
@testable import DeskSwitchCore

final class SleepGuardTests: XCTestCase {
    func testAssertionHeldOnlyWhenHeadlessAndEnabled() {
        XCTAssertTrue(shouldHoldAssertion(headless: true, enabled: true))
        XCTAssertFalse(shouldHoldAssertion(headless: true, enabled: false))
        XCTAssertFalse(shouldHoldAssertion(headless: false, enabled: true))
        XCTAssertFalse(shouldHoldAssertion(headless: false, enabled: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SleepGuardTests`
Expected: compile error — `shouldHoldAssertion` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/DeskSwitchCore/SleepGuard.swift`:

```swift
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
```

- [ ] **Step 4: Wire into serve and app modes**

In `Sources/deskswitch/CLI.swift`, in `Serve.run()`, replace the `RunLoop.main.run()` line with:

```swift
        let sleepTimer = startSleepGuardTimer(config: config, router: router)
        _ = sleepTimer
        RunLoop.main.run()
```

In `Sources/deskswitch/App.swift`, change `Bootstrap.make()`'s success path to start the timer just before returning:

```swift
            let state = MenuState(config: config, router: router, peer: peer,
                                  notifier: UserNotifier())
            _ = startSleepGuardTimer(config: config, router: router)
            return .success((state, server, config))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test && swift build`
Expected: all PASS.

- [ ] **Step 6: Write the M4 checklist**

`docs/verification/m4-checklist.md`:

```markdown
# M4 Verification — Polish (autostart, WoL, notifications, flip-both, sleep)

Prerequisite: M3 checklist passed; rebuilt bundle (scripts/make-app.sh) installed in
/Applications on both Macs.

## Autostart
- [ ] `/Applications/DeskSwitch.app/Contents/MacOS/deskswitch autostart enable` on both Macs
      (approve in System Settings > General > Login Items if prompted)
- [ ] Log out / in: menu bar icon appears without manual launch
- [ ] `kill -9 <pid>` the running deskswitch: launchd restarts it within seconds (KeepAlive)

## Flip both
- [ ] Menu "Send both away" flips both monitors to the peer in one action
- [ ] Menu "Bring both here" pulls both back (forward path)
- [ ] `deskswitch switch all <machine>` does the same from the CLI, reporting per-monitor results

## Notifications
- [ ] Quit the peer app, try a pull from the menu: macOS notification "other Mac offline"
      appears (grant notification permission on first run)
- [ ] Unplug-simulate a DDC failure is impractical — instead verify the notification path
      with the peer-offline case above (same code path via MenuState/Notifier)

## Wake-on-LAN (requires "Wake for network access" ON in System Settings > Energy/Battery
on BOTH Macs; MacBook additionally on power for reliable wake)
- [ ] Confirm `peer.mac` in each config matches the OTHER Mac's active interface MAC
      (`ifconfig en0 | grep ether`)
- [ ] Put the MacBook to sleep, from the mini run `deskswitch switch all macmini` twice if
      needed: magic packet + retry completes the pull (allow one wake cycle ~3-10 s)
- [ ] Remove `peer.mac` from the mini's config temporarily: same action skips the magic
      packet but still retries once — fails with `other Mac offline` after ~4-5 s (two 2 s
      attempts + brief backoff) with a startup warning logged — restore `peer.mac` after
- [ ] Clamshell check (spec risk): repeat the sleep test with the MacBook lid closed

## Headless sleep prevention
- [ ] Set `"preventSleepWhenHeadless": true` on the Mac mini; push both monitors away;
      within ~1 min `pmset -g assertions` on the mini lists PreventSystemSleep from deskswitch
- [ ] Pull a monitor back; within ~1 min the assertion is released
- [ ] Full E2E: TOKEN=<secret> scripts/e2e.sh passes with both Macs on the final build
```

- [ ] **Step 7: Commit**

```bash
git add Sources/DeskSwitchCore/SleepGuard.swift Tests/DeskSwitchCoreTests/SleepGuardTests.swift \
        Sources/deskswitch/App.swift Sources/deskswitch/CLI.swift docs/verification/m4-checklist.md
git commit -m "feat: headless sleep-prevention assertion and M4 checklist (M4 complete)"
```

---

## Plan Self-Review (completed)

- **Spec coverage:** DDC engine → Tasks 3/4/6; HTTP API → 8/9/10; Router → 5; Menu bar UI → 13/14; Config (incl. `peer.mac`/`wol`) → 2; CLI (`status`/`probe`/`switch`/`serve`) → 7/12; push/pull/phone/status flows → 5/9/12 (E2E); error table → 5 (errors) + 16 (WoL retry) + 17 (notifications) + 11 (2 s timeouts); lifecycle → 19 (SMAppService) + 20 (sleep assertion); flip-both → 18; testing strategy → unit tests throughout, hardware checklists (Tasks 7/12/15/20), E2E script (Task 12); milestones M1-M4 → task groups 1-7 / 8-12 / 13-15 / 16-20.
- **Known deviations from spec text:** none in behavior. `listenPort` added to config (spec says "fixed port (default 8377)" — default honored). `switchAll`/`Router` built in M1 task group to keep CLI and M2+ on one code path (DRY); spec milestones describe user-visible capability, which is preserved.
- **Type consistency:** interface names cross-checked across tasks (`DDCEngine`, `PeerClient.requestSwitch(monitor:target:forwarded:)`, `LocalStatus`/`MonitorStatus`, `RouterError.userMessage`, `SwitchRequest`, `makePeerClient` evolution in Tasks 7→12→16).
