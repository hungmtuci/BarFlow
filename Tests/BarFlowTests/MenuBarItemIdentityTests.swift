import Testing
import AppKit
import CoreGraphics
@testable import BarFlow

@Suite("MenuBarItemIdentityTests")
struct MenuBarItemIdentityTests {

    @Test("Digits and percentages in statusDescription normalize to identical IDs")
    func digitsInDescriptionProduceStableIDs() {
        #expect(MenuBarIdentity.normalizeStatusDescriptor("CPU 14%") == "CPU")
        #expect(MenuBarIdentity.normalizeStatusDescriptor("CPU 19%") == "CPU")
        #expect(MenuBarIdentity.normalizeStatusDescriptor("CPU: 14.5 %") == "CPU")
        #expect(MenuBarIdentity.normalizeStatusDescriptor("14%") == nil)
        #expect(MenuBarIdentity.normalizeStatusDescriptor("   ") == nil)

        let scan1 = [
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "CPU 14%", minX: 700, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "Memory 48%", minX: 745, axChildIndex: 1)
        ]
        let scan2 = [
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "CPU 19%", minX: 700, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "Memory 53%", minX: 745, axChildIndex: 1)
        ]

        let ids1 = MenuBarIdentity.makeCaseBItemIDs(baseID: "eu.exelban.Stats", descriptors: scan1).ids
        let ids2 = MenuBarIdentity.makeCaseBItemIDs(baseID: "eu.exelban.Stats", descriptors: scan2).ids

        #expect(ids1 == ["eu.exelban.Stats#CPU", "eu.exelban.Stats#Memory"])
        #expect(ids2 == ids1)
    }

    @Test("Reordering AX children preserves exact per-icon IDs including X-positional fallback")
    func childReorderPreservesSameIDs() {
        // 1. Descriptor/identifier-backed icons reordered in AXChildren
        let forwardDesc = [
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "CPU 14%", minX: 700, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "RAM 61%", minX: 740, axChildIndex: 1)
        ]
        let reversedDesc = [
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "RAM 64%", minX: 740, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "CPU 22%", minX: 700, axChildIndex: 1)
        ]

        let forwardIDs = MenuBarIdentity.makeCaseBItemIDs(baseID: "com.bjango.istatmenus.status", descriptors: forwardDesc).ids
        let reversedIDs = MenuBarIdentity.makeCaseBItemIDs(baseID: "com.bjango.istatmenus.status", descriptors: reversedDesc).ids

        #expect(forwardIDs == ["com.bjango.istatmenus.status#CPU", "com.bjango.istatmenus.status#RAM"])
        #expect(reversedIDs == ["com.bjango.istatmenus.status#RAM", "com.bjango.istatmenus.status#CPU"])
        #expect(Set(forwardIDs) == Set(reversedIDs))

        // 2. Pure X-position fallback when neither axIdentifier nor non-numeric description exists
        let leftThenRight = [
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "14%", minX: 680, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "82%", minX: 720, axChildIndex: 1)
        ]
        let rightThenLeft = [
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "82%", minX: 720, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: nil, statusDescription: "14%", minX: 680, axChildIndex: 1)
        ]

        let posForward = MenuBarIdentity.makeCaseBItemIDs(baseID: "com.example.monitor", descriptors: leftThenRight).ids
        let posReversed = MenuBarIdentity.makeCaseBItemIDs(baseID: "com.example.monitor", descriptors: rightThenLeft).ids

        #expect(posForward == ["com.example.monitor#pos-0", "com.example.monitor#pos-1"])
        // Index 0 in `rightThenLeft` is the right icon (minX=720 -> pos-1); index 1 is the left icon (minX=680 -> pos-0)
        #expect(posReversed == ["com.example.monitor#pos-1", "com.example.monitor#pos-0"])
    }

    @Test("Transitioning from 1 to 2 icons keeps plain baseID on the original first icon")
    func oneToTwoIconsKeepsFirstID() {
        let singleScan = [
            CaseBIconDescriptor(axIdentifier: "sync-status", statusDescription: "Syncing 15%", minX: 810, axChildIndex: 0)
        ]
        let step1 = MenuBarIdentity.makeCaseBItemIDs(
            baseID: "com.microsoft.OneDrive",
            descriptors: singleScan,
            singleIconAnchorKey: nil
        )
        #expect(step1.ids == ["com.microsoft.OneDrive"])
        #expect(step1.updatedSingleIconAnchorKey == "sync-status")

        // Second icon appears and is even placed at AX child index 0 ahead of the original icon
        let twoIconsScan = [
            CaseBIconDescriptor(axIdentifier: "alert-badge", statusDescription: "1 warning", minX: 775, axChildIndex: 0),
            CaseBIconDescriptor(axIdentifier: "sync-status", statusDescription: "Syncing 90%", minX: 810, axChildIndex: 1)
        ]
        let step2 = MenuBarIdentity.makeCaseBItemIDs(
            baseID: "com.microsoft.OneDrive",
            descriptors: twoIconsScan,
            singleIconAnchorKey: step1.updatedSingleIconAnchorKey
        )
        #expect(step2.ids == ["com.microsoft.OneDrive#alert-badge", "com.microsoft.OneDrive"])
    }

    @Test("Multi-icon layout migration maps legacy IDs to new left-to-right IDs once without losing selection or order")
    func migrationMapsOldIDsToNewAndPreservesSelection() {
        var state = MultiIconLayoutSnapshot(
            selectedMainBarIDs: ["com.1password.1password", "com.bjango.istatmenus.status"],
            mainBarOrderIDs: ["com.1password.1password", "com.bjango.istatmenus.status"],
            secondaryBarOrderIDs: ["com.bjango.istatmenus.status#item-1", "com.spotify.client"],
            allAppsOrderIDs: [
                "com.1password.1password",
                "com.bjango.istatmenus.status",
                "com.bjango.istatmenus.status#item-1",
                "com.spotify.client"
            ],
            migratedBaseIDs: []
        )

        let scanned = [
            ScannedMultiIconCandidate(id: "com.1password.1password", baseID: "com.1password.1password", minX: 650, axChildIndex: 0),
            ScannedMultiIconCandidate(id: "com.bjango.istatmenus.status#Memory", baseID: "com.bjango.istatmenus.status", minX: 740, axChildIndex: 0),
            ScannedMultiIconCandidate(id: "com.bjango.istatmenus.status#CPU", baseID: "com.bjango.istatmenus.status", minX: 700, axChildIndex: 1),
            ScannedMultiIconCandidate(id: "com.spotify.client", baseID: "com.spotify.client", minX: 780, axChildIndex: 0)
        ]

        let mapping = MenuBarIdentity.migrateMultiIconIDs(in: &state, scannedCandidates: scanned)

        #expect(mapping == [
            "com.bjango.istatmenus.status": "com.bjango.istatmenus.status#CPU",
            "com.bjango.istatmenus.status#item-1": "com.bjango.istatmenus.status#Memory"
        ])
        #expect(state.selectedMainBarIDs == ["com.1password.1password", "com.bjango.istatmenus.status#CPU"])
        #expect(state.mainBarOrderIDs == ["com.1password.1password", "com.bjango.istatmenus.status#CPU"])
        #expect(state.secondaryBarOrderIDs == ["com.bjango.istatmenus.status#Memory", "com.spotify.client"])
        #expect(state.allAppsOrderIDs == [
            "com.1password.1password",
            "com.bjango.istatmenus.status#CPU",
            "com.bjango.istatmenus.status#Memory",
            "com.spotify.client"
        ])
        #expect(state.migratedBaseIDs.contains("com.bjango.istatmenus.status"))

        // Second pass must be a no-op so subsequent user changes are never overwritten
        let secondMapping = MenuBarIdentity.migrateMultiIconIDs(in: &state, scannedCandidates: scanned)
        #expect(secondMapping.isEmpty)
    }

    @Test("System extras without axIdentifier prefer semantic symbol key and deterministic dedup chooses live on-bar winner")
    func systemExtraIDsAndDeterministicDedup() {
        let sysDescriptors = [
            SystemExtraDescriptor(containerBundleID: "com.apple.controlcenter", axIdentifier: nil, title: "", statusDescription: "Wi-Fi 100%", minX: 880, axChildIndex: 0),
            SystemExtraDescriptor(containerBundleID: "com.apple.controlcenter", axIdentifier: "com.apple.menuextra.battery", title: "98%", statusDescription: "Battery", minX: 910, axChildIndex: 1),
            SystemExtraDescriptor(containerBundleID: "com.apple.controlcenter", axIdentifier: nil, title: "", statusDescription: "Custom Sensor 42%", minX: 850, axChildIndex: 2)
        ]
        let sysIDs = MenuBarIdentity.makeSystemExtraItemIDs(descriptors: sysDescriptors)
        #expect(sysIDs == [
            "systemextra:wifi",
            "com.apple.menuextra.battery",
            "systemextra:com.apple.controlcenter:CustomSensor"
        ])

        // Persisted hidden system item merge should NOT match on appName alone when IDs differ
        #expect(
            MenuBarIdentity.matchesPersistedHiddenSystemItem(
                existingID: "systemextra:bluetooth",
                existingAXIdentifier: nil,
                existingAppName: "Tiện ích hệ thống",
                existingIsSystemItem: true,
                persistedID: "systemextra:wifi",
                persistedAXIdentifier: nil,
                persistedAppName: "Tiện ích hệ thống"
            ) == false
        )

        // Deterministic dedup: on-bar + non-nil frame + lower PID wins regardless of concurrent worker arrival order
        let icon = NSImage()
        let loser = MenuBarAppItem(
            id: "com.example.shared",
            pid: 900,
            appName: "Shared Helper",
            bundleIdentifier: "com.example.shared",
            axIdentifier: nil,
            axChildIndex: 1,
            appIcon: icon,
            statusTitle: "",
            statusDescription: "",
            slotFrame: nil,
            isCurrentlyOnBar: false,
            axElement: nil,
            isSystemItem: false,
            isMovable: true
        )
        let winner = MenuBarAppItem(
            id: "com.example.shared",
            pid: 450,
            appName: "Shared Main",
            bundleIdentifier: "com.example.shared",
            axIdentifier: nil,
            axChildIndex: 0,
            appIcon: icon,
            statusTitle: "",
            statusDescription: "",
            slotFrame: CGRect(x: 720, y: 0, width: 28, height: 24),
            isCurrentlyOnBar: true,
            axElement: nil,
            isSystemItem: false,
            isMovable: true
        )

        let dedupA = MenuBarIdentity.deduplicateItemsDeterministically([loser, winner])
        let dedupB = MenuBarIdentity.deduplicateItemsDeterministically([winner, loser])
        #expect(dedupA.count == 1)
        #expect(dedupA.first?.pid == 450)
        #expect(dedupB.first?.pid == 450)
    }

    @Test("Multi-display MenuBarAgent slot helpers deduplicate frames and select display with complete slot set")
    func multiDisplaySlotHelpers() {
        let builtIn = DisplayGeometry(
            displayID: 1,
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cgFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            menuBarThickness: 38
        )
        let external = DisplayGeometry(
            displayID: 2,
            appKitFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            cgFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1440),
            menuBarThickness: 24
        )
        let displays = [builtIn, external]

        let slotOnBuiltIn = CGRect(x: 1120, y: 4, width: 28, height: 24)
        let slotOnExternal = CGRect(x: 3600, y: -456, width: 28, height: 24)
        #expect(MenuBarScanner.isFrameVisiblyOnMenuBar(slotOnBuiltIn, displays: displays) == true)
        #expect(MenuBarScanner.isFrameVisiblyOnMenuBar(slotOnExternal, displays: displays) == true)
        #expect(MenuBarScanner.containsMatchingSlotFrame([slotOnBuiltIn], candidate: CGRect(x: 1120.4, y: 4.2, width: 28, height: 24)) == true)
        #expect(MenuBarScanner.containsMatchingSlotFrame([slotOnBuiltIn], candidate: slotOnExternal) == false)

        // Single-icon app mirrored across both displays -> selects 1 slot (not 2 duplicates)
        let mirroredSingle = MenuBarScanner.selectBestDisplaySlotIndices(
            slotFrames: [slotOnBuiltIn, slotOnExternal],
            displays: displays
        )
        #expect(mirroredSingle.count == 1)

        // 3-icon app clipped to 2 icons on notched built-in display, all 3 visible on external monitor -> selects all 3
        let multiIconFrames: [CGRect?] = [
            CGRect(x: 1100, y: 4, width: 28, height: 24),
            CGRect(x: 1132, y: 4, width: 28, height: 24),
            CGRect(x: 3500, y: -456, width: 28, height: 24),
            CGRect(x: 3532, y: -456, width: 28, height: 24),
            CGRect(x: 3564, y: -456, width: 28, height: 24)
        ]
        let selectedMulti = MenuBarScanner.selectBestDisplaySlotIndices(
            slotFrames: multiIconFrames,
            displays: displays
        )
        #expect(selectedMulti == [2, 3, 4])
    }

    @Test("Semantic version comparison compares numeric components correctly")
    func semanticVersionComparison() {
        #expect(UpdateCheckerService.isVersion("1.10.0", newerThan: "1.9.3") == true)
        #expect(UpdateCheckerService.isVersion("1.9.3", newerThan: "1.10.0") == false)
        #expect(UpdateCheckerService.isVersion("1.9.10", newerThan: "1.9.3") == true)
        #expect(UpdateCheckerService.isVersion("1.10.0", newerThan: "1.10.0") == false)
        #expect(UpdateCheckerService.isVersion("v1.10.0", newerThan: "v1.10.0") == false)
    }
}
