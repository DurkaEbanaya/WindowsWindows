import Darwin
import XCTest
@testable import WindowsWindows

final class ConfigurationContractTests: XCTestCase {
    private var rootURL: URL!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowsWindowsTests-\(UUID().uuidString)", isDirectory: true)
        store = try ConfigStore(supportURL: rootURL)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testVersion1ConfigurationMigratesAndPersistsVersion2() throws {
        let version1 = """
        {
          "scopeMode": "onlyListed",
          "bundleIdentifiers": ["com.brave.Browser", "com.brave.Browser", " ai.opencode.desktop "],
          "refreshInterval": 0.1,
          "snapshotInterval": 0.05
        }
        """
        try Data(version1.utf8).write(to: store.configURL)

        let config = try store.load()

        XCTAssertEqual(config.scopeMode, .onlyListed)
        XCTAssertEqual(config.bundleIdentifiers, ["ai.opencode.desktop", "com.brave.Browser"])
        XCTAssertEqual(config.refreshInterval, 0.25)
        XCTAssertEqual(config.snapshotInterval, 0.25)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: store.configURL))
        let dictionary = try XCTUnwrap(persisted as? [String: Any])
        XCTAssertEqual(dictionary["schemaVersion"] as? Int, ShelfConfig.currentSchemaVersion)
    }

    func testMalformedConfigurationIsNotOverwritten() throws {
        let malformed = Data(#"{"scopeMode":"onlyListed""#.utf8)
        try malformed.write(to: store.configURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.configURL), malformed)
    }

    func testFutureSchemaIsNotOverwritten() throws {
        let future = Data("""
        {
          "schemaVersion": 999,
          "scopeMode": "onlyListed",
          "bundleIdentifiers": [],
          "refreshInterval": 2,
          "snapshotInterval": 5
        }
        """.utf8)
        try future.write(to: store.configURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ShelfConfigSchemaError, .unsupportedVersion(999))
        }
        XCTAssertEqual(try Data(contentsOf: store.configURL), future)
    }

    func testNullSchemaIsNotTreatedAsLegacy() throws {
        let invalid = Data("""
        {
          "schemaVersion": null,
          "scopeMode": "onlyListed",
          "bundleIdentifiers": [],
          "refreshInterval": 2,
          "snapshotInterval": 5
        }
        """.utf8)
        try invalid.write(to: store.configURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.configURL), invalid)
    }

    func testIncompleteSnapshotProtectsLegacyAndMatchingLifetimeOnly() throws {
        let pid = getpid()
        let identity = try XCTUnwrap(ProcessIdentity.live(processIdentifier: pid))
        let key = WindowKey(appPID: pid, windowNumber: 42)
        let snapshot = WindowDiscoverySnapshot(
            windows: [],
            incompleteApplications: [identity]
        )

        XCTAssertFalse(snapshot.isAbsenceAuthoritative(for: key, persistedProcessIdentity: nil))
        XCTAssertFalse(snapshot.isAbsenceAuthoritative(for: key, persistedProcessIdentity: identity))
        let priorLifetime = try XCTUnwrap(ProcessIdentity(
            processIdentifier: pid,
            startTimeSeconds: identity.startTimeSeconds + 1,
            startTimeMicroseconds: identity.startTimeMicroseconds
        ))
        XCTAssertTrue(snapshot.isAbsenceAuthoritative(for: key, persistedProcessIdentity: priorLifetime))
    }

    func testUnidentifiedSnapshotProtectsOnlyVerifiedMatchingLifetime() throws {
        let pid = getpid()
        let identity = try XCTUnwrap(ProcessIdentity.live(processIdentifier: pid))
        let key = WindowKey(appPID: pid, windowNumber: 42)
        let snapshot = WindowDiscoverySnapshot(
            windows: [],
            incompleteApplications: [],
            unidentifiedApplicationPIDs: [pid]
        )

        XCTAssertFalse(snapshot.isAbsenceAuthoritative(for: key, persistedProcessIdentity: nil))
        XCTAssertFalse(snapshot.isAbsenceAuthoritative(for: key, persistedProcessIdentity: identity))
        let priorLifetime = try XCTUnwrap(ProcessIdentity(
            processIdentifier: pid,
            startTimeSeconds: identity.startTimeSeconds + 1,
            startTimeMicroseconds: identity.startTimeMicroseconds
        ))
        XCTAssertTrue(snapshot.isAbsenceAuthoritative(for: key, persistedProcessIdentity: priorLifetime))
    }

    func testProcessIdentityIncludesProcessLifetime() throws {
        let pid = getpid()
        let first = try XCTUnwrap(ProcessIdentity.live(processIdentifier: pid))
        let second = try XCTUnwrap(ProcessIdentity.live(processIdentifier: pid))
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            ProcessIdentity(
                processIdentifier: pid,
                startTimeSeconds: first.startTimeSeconds + 1,
                startTimeMicroseconds: first.startTimeMicroseconds
            )
        )
    }

    func testFactoryRemovesMalformedOwnedBundles() throws {
        let proxyRoot = rootURL.appendingPathComponent("ProxyApps", isDirectory: true)
        let malformedBundle = proxyRoot.appendingPathComponent("Malformed.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: malformedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not a plist".utf8).write(
            to: malformedBundle.appendingPathComponent("Contents/Info.plist")
        )
        let binary = rootURL.appendingPathComponent("WindowsWindowsProxy")
        try Data().write(to: binary)
        let factory = ProxyFactory(proxyAppsURL: proxyRoot, proxyBinaryURL: binary)
        let removed = try factory.removeInvalidProxyBundles()

        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.lastPathComponent, malformedBundle.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedBundle.path))
    }

    func testProxyIPCParsesLegacyActivationWithoutAction() throws {
        let key = WindowKey(appPID: 123, windowNumber: 456)

        let message = try XCTUnwrap(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue
        ]))

        XCTAssertEqual(message, ProxyIPCMessage(action: .activate, windowKey: key))
    }

    func testProxyIPCParsesExplicitCloseActionAndRejectsUnknownActions() throws {
        let key = WindowKey(appPID: 123, windowNumber: 456)

        let message = try XCTUnwrap(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue,
            ProxyIPC.actionUserInfoKey: ProxyIPCAction.close.rawValue,
        ]))

        XCTAssertEqual(message, ProxyIPCMessage(action: .close, windowKey: key))
        XCTAssertNil(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue,
            ProxyIPC.actionUserInfoKey: "delete-everything",
        ]))
    }

    func testCloseProxySuppressionIsBoundedAndClearsWhenWindowDisappears() {
        let key = WindowKey(appPID: 123, windowNumber: 456)
        let other = WindowKey(appPID: 123, windowNumber: 789)
        let now = Date(timeIntervalSince1970: 1_000)
        var suppressions = CloseProxySuppressionState()

        suppressions.suppress(key: key, now: now, duration: 2)

        XCTAssertTrue(suppressions.isSuppressed(key: key, now: now.addingTimeInterval(1)))
        XCTAssertFalse(suppressions.isSuppressed(key: other, now: now.addingTimeInterval(1)))
        suppressions.removeObservedKeys([], now: now.addingTimeInterval(1))
        XCTAssertFalse(suppressions.isSuppressed(key: key, now: now.addingTimeInterval(1)))

        suppressions.suppress(key: key, now: now, duration: 2)
        XCTAssertFalse(suppressions.isSuppressed(key: key, now: now.addingTimeInterval(3)))
    }
}
