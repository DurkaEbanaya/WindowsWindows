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

    func testVersion1ConfigurationMigratesIntoDefaultWorkspaceProfile() throws {
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
        XCTAssertEqual(dictionary["schemaVersion"] as? Int, WorkspaceConfig.currentSchemaVersion)
        XCTAssertEqual(dictionary["activeProfileID"] as? String, WorkspaceConfig.defaultProfileID)
        let profiles = try XCTUnwrap(dictionary["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?["id"] as? String, WorkspaceConfig.defaultProfileID)
    }

    func testWorkspaceCompatibilityUpdateMutatesOnlyActiveProfile() throws {
        let workspace = WorkspaceConfig(activeProfileID: "work", profiles: [
            WorkspaceProfile(
                id: "default",
                name: "Default",
                shelfConfig: ShelfConfig(scopeMode: .allExceptListed, bundleIdentifiers: ["com.default"])
            ),
            WorkspaceProfile(
                id: "work",
                name: "Work",
                shelfConfig: ShelfConfig(scopeMode: .onlyListed, bundleIdentifiers: ["com.old"])
            ),
        ])
        try store.saveWorkspace(workspace)

        let active = try store.update { config in
            config.bundleIdentifiers = ["com.new"]
        }

        XCTAssertEqual(active.bundleIdentifiers, ["com.new"])
        let reloaded = try store.loadWorkspace()
        XCTAssertEqual(reloaded.activeProfileID, "work")
        XCTAssertEqual(reloaded.profiles.first { $0.id == "default" }?.shelfConfig.bundleIdentifiers, ["com.default"])
        XCTAssertEqual(reloaded.profiles.first { $0.id == "work" }?.shelfConfig.bundleIdentifiers, ["com.new"])
    }

    func testWorkspaceAssignsNewWindowsToActiveProfileAndPrunesClosedWindows() throws {
        let first = WindowKey(appPID: 10, windowNumber: 1)
        let second = WindowKey(appPID: 10, windowNumber: 2)
        var workspace = WorkspaceConfig(activeProfileID: "work", profiles: [
            WorkspaceProfile(
                id: "default",
                name: "Default",
                shelfConfig: .default,
                windowKeys: [first.stringValue]
            ),
            WorkspaceProfile(id: "work", name: "Work", shelfConfig: .default),
        ])

        XCTAssertTrue(try workspace.assignNewWindowsToActiveProfile([first, second]))

        XCTAssertEqual(workspace.profiles.first { $0.id == "default" }?.windowKeys, [first.stringValue])
        XCTAssertEqual(workspace.profiles.first { $0.id == "work" }?.windowKeys, [second.stringValue])
        XCTAssertEqual(workspace.activeWindowKeySet(), [second])

        XCTAssertTrue(try workspace.assignNewWindowsToActiveProfile([second]))
        XCTAssertEqual(workspace.profiles.first { $0.id == "default" }?.windowKeys, [])
        XCTAssertEqual(workspace.profiles.first { $0.id == "work" }?.windowKeys, [second.stringValue])
    }

    func testWorkspaceUpdateConfigUsesVerifiedGitHubReleasesEndpoint() throws {
        let updates = WorkspaceUpdateConfig.default

        XCTAssertEqual(
            updates.releasesAPIURL.absoluteString,
            "https://api.github.com/repos/DurkaEbanaya/WindowsWindows/releases"
        )
        XCTAssertEqual(
            updates.sparkleAppcastURL.absoluteString,
            "https://durkaebanaya.github.io/WindowsWindows/appcast.xml"
        )
    }

    func testWorkspaceBehaviorAndAppearanceDefaultsAreMigrated() throws {
        let version2 = """
        {
          "schemaVersion": 2,
          "scopeMode": "allExceptListed",
          "bundleIdentifiers": [],
          "refreshInterval": 2,
          "snapshotInterval": 5
        }
        """
        try Data(version2.utf8).write(to: store.configURL)

        let workspace = try store.loadWorkspace()

        XCTAssertTrue(workspace.behavior.minimizeOnRepeatClick)
        XCTAssertTrue(workspace.behavior.optionTabSwitcherEnabled)
        XCTAssertTrue(workspace.behavior.dockWindowTilesEnabled)
        XCTAssertEqual(workspace.appearance.theme, .system)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: store.configURL))
        let dictionary = try XCTUnwrap(persisted as? [String: Any])
        XCTAssertNotNil(dictionary["behavior"])
        XCTAssertNotNil(dictionary["appearance"])
    }

    func testInvalidWorkspaceIsNotOverwritten() throws {
        let invalid = Data("""
        {
          "schemaVersion": 3,
          "activeProfileID": "missing",
          "profiles": [
            {
              "id": "default",
              "name": "Default",
              "shelfConfig": {
                "schemaVersion": 2,
                "scopeMode": "allExceptListed",
                "bundleIdentifiers": [],
                "refreshInterval": 2,
                "snapshotInterval": 5
              }
            }
          ]
        }
        """.utf8)
        try invalid.write(to: store.configURL)

        XCTAssertThrowsError(try store.loadWorkspace()) { error in
            XCTAssertEqual(error as? WorkspaceConfigValidationError, .activeProfileMissing("missing"))
        }
        XCTAssertEqual(try Data(contentsOf: store.configURL), invalid)
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
        XCTAssertTrue(first.isLiveProcess)
        XCTAssertNotEqual(
            first,
            ProcessIdentity(
                processIdentifier: pid,
                startTimeSeconds: first.startTimeSeconds + 1,
                startTimeMicroseconds: first.startTimeMicroseconds
            )
        )
        XCTAssertFalse(
            ProcessIdentity(
                processIdentifier: pid,
                startTimeSeconds: first.startTimeSeconds + 1,
                startTimeMicroseconds: first.startTimeMicroseconds
            )?.isLiveProcess ?? true
        )
    }

    func testMainInstanceLockIsExclusiveForProcessLifetime() throws {
        let lockURL = rootURL.appendingPathComponent("main.lock", isDirectory: false)

        let first = try XCTUnwrap(MainInstanceLock.acquire(lockURL: lockURL))
        XCTAssertNil(try MainInstanceLock.acquire(lockURL: lockURL))
        _ = first
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

    func testProxyIPCRejectsLegacyActivationWithoutSessionToken() throws {
        let key = WindowKey(appPID: 123, windowNumber: 456)

        XCTAssertNil(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue
        ], expectedSessionToken: "expected"))
    }

    func testProxyIPCParsesExplicitCloseActionAndRejectsUnknownActions() throws {
        let key = WindowKey(appPID: 123, windowNumber: 456)
        let token = UUID().uuidString

        let message = try XCTUnwrap(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue,
            ProxyIPC.actionUserInfoKey: ProxyIPCAction.close.rawValue,
            ProxyIPC.sessionTokenUserInfoKey: token,
        ], expectedSessionToken: token))

        XCTAssertEqual(message, ProxyIPCMessage(action: .close, windowKey: key))
        XCTAssertNil(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue,
            ProxyIPC.actionUserInfoKey: "delete-everything",
            ProxyIPC.sessionTokenUserInfoKey: token,
        ], expectedSessionToken: token))
        XCTAssertNil(ProxyIPCMessage(userInfo: [
            ProxyIPC.windowKeyUserInfoKey: key.stringValue,
            ProxyIPC.actionUserInfoKey: ProxyIPCAction.activate.rawValue,
            ProxyIPC.sessionTokenUserInfoKey: "wrong",
        ], expectedSessionToken: token))
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

    func testWindowSwitchSelectionStartsAfterFocusedWindowAndWrapsBothDirections() {
        let first = WindowKey(appPID: 1, windowNumber: 1)
        let second = WindowKey(appPID: 2, windowNumber: 2)
        let third = WindowKey(appPID: 3, windowNumber: 3)

        var forward = WindowSwitchSelection(keys: [first, second, third], focusedKey: first, reverse: false)
        XCTAssertEqual(forward.selectedKey, second)
        forward.advance(reverse: false)
        XCTAssertEqual(forward.selectedKey, third)
        forward.advance(reverse: false)
        XCTAssertEqual(forward.selectedKey, first)

        var reverse = WindowSwitchSelection(keys: [first, second, third], focusedKey: first, reverse: true)
        XCTAssertEqual(reverse.selectedKey, third)
        reverse.advance(reverse: true)
        XCTAssertEqual(reverse.selectedKey, second)
        reverse.select(index: 0)
        XCTAssertEqual(reverse.selectedKey, first)
    }


    func testLegacyBehaviorObjectDefaultsOptionTabSwitcherToEnabled() throws {
        let data = Data(#"{"minimizeOnRepeatClick":false}"#.utf8)
        let behavior = try JSONDecoder().decode(WorkspaceBehaviorConfig.self, from: data)

        XCTAssertFalse(behavior.minimizeOnRepeatClick)
        XCTAssertTrue(behavior.optionTabSwitcherEnabled)
        XCTAssertTrue(behavior.dockWindowTilesEnabled)
    }

    func testWindowPresentationModesPersistIndependently() throws {
        let behavior = WorkspaceBehaviorConfig(
            optionTabSwitcherEnabled: true,
            dockWindowTilesEnabled: false
        )
        let decoded = try JSONDecoder().decode(
            WorkspaceBehaviorConfig.self,
            from: JSONEncoder().encode(behavior)
        )

        XCTAssertTrue(decoded.optionTabSwitcherEnabled)
        XCTAssertFalse(decoded.dockWindowTilesEnabled)
    }

    func testOptionTabOnlyModeStillCapturesPreviewsWithoutDockProjection() {
        let plan = WindowPresentationPlan(behavior: WorkspaceBehaviorConfig(
            optionTabSwitcherEnabled: true,
            dockWindowTilesEnabled: false
        ))

        XCTAssertTrue(plan.capturesPreviews)
        XCTAssertFalse(plan.projectsDockTiles)
    }

    func testDockRepeatClickMinimizesOnlyTheAlreadyFrontmostNonProxyApplication() {
        XCTAssertEqual(
            DockRepeatClickDecision.decide(
                clickedApplicationPID: 42,
                frontmostApplicationPID: 42,
                isProxyApplication: false
            ),
            .minimize
        )
        XCTAssertEqual(
            DockRepeatClickDecision.decide(
                clickedApplicationPID: 42,
                frontmostApplicationPID: 21,
                isProxyApplication: false
            ),
            .ignore
        )
        XCTAssertEqual(
            DockRepeatClickDecision.decide(
                clickedApplicationPID: 42,
                frontmostApplicationPID: 42,
                isProxyApplication: true
            ),
            .ignore
        )
    }
}
