import Foundation
import CoreGraphics

/// Pure descriptor of a single `AXExtrasMenuBar` child for a standard or helper application (Case B).
/// Contains zero Accessibility references so identity assignment is 100% deterministic and unit-testable.
struct CaseBIconDescriptor: Equatable, Sendable {
    let axIdentifier: String?
    let statusDescription: String
    let minX: CGFloat?
    let axChildIndex: Int

    init(
        axIdentifier: String? = nil,
        statusDescription: String = "",
        minX: CGFloat? = nil,
        axChildIndex: Int = 0
    ) {
        self.axIdentifier = axIdentifier
        self.statusDescription = statusDescription
        self.minX = minX
        self.axChildIndex = axChildIndex
    }
}

/// Pure descriptor of a single movable macOS System Menu Extra (Case A).
struct SystemExtraDescriptor: Equatable, Sendable {
    let containerBundleID: String?
    let axIdentifier: String?
    let title: String
    let statusDescription: String
    let minX: CGFloat?
    let axChildIndex: Int

    init(
        containerBundleID: String? = nil,
        axIdentifier: String? = nil,
        title: String = "",
        statusDescription: String = "",
        minX: CGFloat? = nil,
        axChildIndex: Int = 0
    ) {
        self.containerBundleID = containerBundleID
        self.axIdentifier = axIdentifier
        self.title = title
        self.statusDescription = statusDescription
        self.minX = minX
        self.axChildIndex = axChildIndex
    }
}

/// Pure snapshot of saved layout arrays for deterministic one-time multi-icon ID migration.
struct MultiIconLayoutSnapshot: Equatable, Sendable {
    var selectedMainBarIDs: Set<String>
    var mainBarOrderIDs: [String]
    var secondaryBarOrderIDs: [String]
    var allAppsOrderIDs: [String]
    var migratedBaseIDs: Set<String>

    init(
        selectedMainBarIDs: Set<String> = [],
        mainBarOrderIDs: [String] = [],
        secondaryBarOrderIDs: [String] = [],
        allAppsOrderIDs: [String] = [],
        migratedBaseIDs: Set<String> = []
    ) {
        self.selectedMainBarIDs = selectedMainBarIDs
        self.mainBarOrderIDs = mainBarOrderIDs
        self.secondaryBarOrderIDs = secondaryBarOrderIDs
        self.allAppsOrderIDs = allAppsOrderIDs
        self.migratedBaseIDs = migratedBaseIDs
    }
}

/// Pure descriptor of a discovered item used by `MenuBarIdentity.migrateMultiIconIDs`.
struct ScannedMultiIconCandidate: Equatable, Sendable {
    let id: String
    let baseID: String
    let minX: CGFloat?
    let axChildIndex: Int

    init(id: String, baseID: String, minX: CGFloat?, axChildIndex: Int = 0) {
        self.id = id
        self.baseID = baseID
        self.minX = minX
        self.axChildIndex = axChildIndex
    }
}

/// Pure, side-effect-free identity, deduplication, and layout-migration algorithms for BarFlow.
enum MenuBarIdentity {
    private static let trimPunctuationSet = CharacterSet(charactersIn: ".:,;/-_•|()[]{}")

    /// Strips decimal digits, `%`, numeric decimal separators, and whitespace runs from a status description.
    /// Returns `nil` when nothing meaningful remains (e.g. `"14%"` or `"   "`), while mapping
    /// `"CPU 14%"`, `"CPU 19%"`, and `"CPU: 14.5%"` deterministically to `"CPU"`.
    static func normalizeStatusDescriptor(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        let scalars = Array(raw.unicodeScalars)
        var filtered = String.UnicodeScalarView()
        filtered.reserveCapacity(scalars.count)

        for i in scalars.indices {
            let scalar = scalars[i]
            if CharacterSet.decimalDigits.contains(scalar) {
                continue
            }
            if scalar == "%" {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            // Drop decimal/thousands separators `.` or `,` that were adjacent to digits (e.g. "14.5%" or "1,024")
            if scalar == "." || scalar == "," {
                let prevIsDigit = i > 0 && CharacterSet.decimalDigits.contains(scalars[i - 1])
                let nextIsDigit = (i + 1) < scalars.count && CharacterSet.decimalDigits.contains(scalars[i + 1])
                if prevIsDigit || nextIsDigit {
                    continue
                }
            }
            filtered.append(scalar)
        }

        let cleaned = String(filtered).trimmingCharacters(in: trimPunctuationSet)
        guard !cleaned.isEmpty else { return nil }
        let hasIdentifierChar = cleaned.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.symbols.contains($0)
        }
        return hasIdentifierChar ? cleaned : nil
    }

    /// Computes stable Case B item IDs for a process's status items without any AX calls.
    /// - Single-icon apps (`descriptors.count == 1`) receive plain `baseID` (preserving backward compatibility)
    ///   and return their natural disambiguator key as `updatedSingleIconAnchorKey`.
    /// - Multi-icon apps (`descriptors.count >= 2`) use `baseID#<axIdentifier>`, else `baseID#<normalizedDesc>`,
    ///   else `baseID#pos-N` where `N` is 0-based left-to-right X rank (`slotFrame.minX`), never AX child index.
    /// - If the app previously had 1 icon in this session (`singleIconAnchorKey != nil`), the anchored icon keeps
    ///   plain `baseID` when a 2nd+ icon appears (`1 -> 2` transition), regardless of AX child ordering.
    static func makeCaseBItemIDs(
        baseID: String,
        descriptors: [CaseBIconDescriptor],
        singleIconAnchorKey: String? = nil
    ) -> (ids: [String], updatedSingleIconAnchorKey: String?) {
        guard !descriptors.isEmpty else {
            return ([], singleIconAnchorKey)
        }

        let sortedIndicesByX = descriptors.indices.sorted { a, b in
            let da = descriptors[a]
            let db = descriptors[b]
            if (da.minX != nil) != (db.minX != nil) {
                return da.minX != nil
            }
            if let ax = da.minX, let bx = db.minX, abs(ax - bx) > 0.5 {
                return ax < bx
            }
            let idA = da.axIdentifier ?? ""
            let idB = db.axIdentifier ?? ""
            if idA != idB {
                return idA < idB
            }
            let normA = normalizeStatusDescriptor(da.statusDescription) ?? ""
            let normB = normalizeStatusDescriptor(db.statusDescription) ?? ""
            if normA != normB {
                return normA < normB
            }
            return da.axChildIndex < db.axChildIndex
        }

        var xRankByIndex = [Int](repeating: 0, count: descriptors.count)
        for (rank, originalIdx) in sortedIndicesByX.enumerated() {
            xRankByIndex[originalIdx] = rank
        }

        var rawKeys = [String](repeating: "", count: descriptors.count)
        for idx in descriptors.indices {
            let d = descriptors[idx]
            if let axID = d.axIdentifier, !axID.isEmpty {
                rawKeys[idx] = axID
            } else if let normDesc = normalizeStatusDescriptor(d.statusDescription) {
                rawKeys[idx] = normDesc
            } else {
                rawKeys[idx] = "pos-\(xRankByIndex[idx])"
            }
        }

        // Deduplicate colliding disambiguator keys deterministically in left-to-right X order
        var seenKeyCounts: [String: Int] = [:]
        var uniqueKeys = [String](repeating: "", count: descriptors.count)
        for idx in sortedIndicesByX {
            let baseKey = rawKeys[idx]
            let count = (seenKeyCounts[baseKey] ?? 0) + 1
            seenKeyCounts[baseKey] = count
            uniqueKeys[idx] = (count == 1) ? baseKey : "\(baseKey)-\(count)"
        }

        if descriptors.count == 1 {
            return ([baseID], uniqueKeys[0])
        }

        if let anchor = singleIconAnchorKey,
           let anchoredIdx = sortedIndicesByX.first(where: { uniqueKeys[$0] == anchor }) {
            var ids = [String](repeating: "", count: descriptors.count)
            for idx in descriptors.indices {
                ids[idx] = (idx == anchoredIdx) ? baseID : "\(baseID)#\(uniqueKeys[idx])"
            }
            return (ids, anchor)
        }

        let ids = descriptors.indices.map { "\(baseID)#\(uniqueKeys[$0])" }
        return (ids, nil)
    }

    /// Computes stable Case A IDs for movable macOS System Menu Extras:
    /// - Uses `axIdentifier` directly when present (`com.apple.menuextra.*`).
    /// - Otherwise prefers known semantic `symbolKey` (`systemextra:wifi`, `systemextra:battery`, etc.) when not `"default"`.
    /// - Otherwise uses normalized `statusDescription`, falling back to X-sorted position (`pos-N`).
    static func makeSystemExtraItemIDs(descriptors: [SystemExtraDescriptor]) -> [String] {
        guard !descriptors.isEmpty else { return [] }

        let sortedIndicesByX = descriptors.indices.sorted { a, b in
            let da = descriptors[a]
            let db = descriptors[b]
            if (da.minX != nil) != (db.minX != nil) {
                return da.minX != nil
            }
            if let ax = da.minX, let bx = db.minX, abs(ax - bx) > 0.5 {
                return ax < bx
            }
            return da.axChildIndex < db.axChildIndex
        }

        var xRankByIndex = [Int](repeating: 0, count: descriptors.count)
        for (rank, originalIdx) in sortedIndicesByX.enumerated() {
            xRankByIndex[originalIdx] = rank
        }

        var rawIDs = [String](repeating: "", count: descriptors.count)
        for idx in descriptors.indices {
            let d = descriptors[idx]
            if let axID = d.axIdentifier, !axID.isEmpty {
                rawIDs[idx] = axID
                continue
            }
            let (_, symbolKey) = MenuBarScanner.systemExtraPresentation(
                axID: nil,
                title: d.title,
                desc: d.statusDescription
            )
            if symbolKey != "default" {
                rawIDs[idx] = "systemextra:\(symbolKey)"
            } else if let normDesc = normalizeStatusDescriptor(d.statusDescription) {
                rawIDs[idx] = "systemextra:\(d.containerBundleID ?? "macos"):\(normDesc)"
            } else {
                rawIDs[idx] = "systemextra:\(d.containerBundleID ?? "macos"):pos-\(xRankByIndex[idx])"
            }
        }

        var seenCounts: [String: Int] = [:]
        var finalIDs = [String](repeating: "", count: descriptors.count)
        for idx in sortedIndicesByX {
            let candidate = rawIDs[idx]
            let count = (seenCounts[candidate] ?? 0) + 1
            seenCounts[candidate] = count
            finalIDs[idx] = (count == 1) ? candidate : "\(candidate)#\(count)"
        }
        return finalIDs
    }

    /// Deterministic deduplication: sorts candidates by
    /// (`isCurrentlyOnBar` desc, `slotFrame != nil` desc, live `pid > 0` desc, `pid` asc, `axChildIndex` asc)
    /// before keeping the first entry per `id`.
    static func deduplicateItemsDeterministically(_ discovered: [MenuBarAppItem]) -> [MenuBarAppItem] {
        guard discovered.count > 1 else { return discovered }

        let ordered = discovered.sorted { a, b in
            if a.isCurrentlyOnBar != b.isCurrentlyOnBar {
                return a.isCurrentlyOnBar && !b.isCurrentlyOnBar
            }
            let aHasFrame = (a.slotFrame != nil)
            let bHasFrame = (b.slotFrame != nil)
            if aHasFrame != bHasFrame {
                return aHasFrame && !bHasFrame
            }
            let aHasLivePID = (a.pid > 0)
            let bHasLivePID = (b.pid > 0)
            if aHasLivePID != bHasLivePID {
                return aHasLivePID && !bHasLivePID
            }
            if a.pid != b.pid {
                return a.pid < b.pid
            }
            return a.axChildIndex < b.axChildIndex
        }

        var uniqueByID = Set<String>()
        uniqueByID.reserveCapacity(ordered.count)
        var deduplicated: [MenuBarAppItem] = []
        deduplicated.reserveCapacity(ordered.count)
        for item in ordered where uniqueByID.insert(item.id).inserted {
            deduplicated.append(item)
        }
        return deduplicated
    }

    /// Determines whether an already-discovered item matches a persisted hidden system extra.
    /// Name-only matching (`appName == persistedAppName`) is restricted strictly to the fallback case
    /// where neither side has an `id` or `axIdentifier`.
    static func matchesPersistedHiddenSystemItem(
        existingID: String,
        existingAXIdentifier: String?,
        existingAppName: String,
        existingIsSystemItem: Bool,
        persistedID: String,
        persistedAXIdentifier: String?,
        persistedAppName: String
    ) -> Bool {
        if !existingID.isEmpty && !persistedID.isEmpty && existingID == persistedID {
            return true
        }
        if let pa = persistedAXIdentifier, !pa.isEmpty,
           let ea = existingAXIdentifier, !ea.isEmpty,
           ea == pa {
            return true
        }
        let existingHasIdentity = !existingID.isEmpty || (existingAXIdentifier?.isEmpty == false)
        let persistedHasIdentity = !persistedID.isEmpty || (persistedAXIdentifier?.isEmpty == false)
        if !existingHasIdentity && !persistedHasIdentity {
            return existingIsSystemItem && existingAppName == persistedAppName
        }
        return false
    }

    /// Returns `true` when `itemID` belongs to `baseID` (either exact `baseID` or prefixed with `baseID#`).
    static func belongsToBaseID(_ itemID: String, baseID: String) -> Bool {
        itemID == baseID || itemID.hasPrefix(baseID + "#")
    }

    /// Extracts `baseID` from a Case B item (`bundleIdentifier` if non-empty, else prefix before `#`).
    static func baseID(for item: MenuBarAppItem) -> String? {
        if item.isSystemItem {
            return nil
        }
        if let bid = item.bundleIdentifier, !bid.isEmpty {
            return bid
        }
        if let hashIdx = item.id.firstIndex(of: "#") {
            return String(item.id[..<hashIdx])
        }
        return item.id.isEmpty ? nil : item.id
    }

    /// One-time migration mapping legacy multi-icon saved IDs (`baseID`, `baseID#item-1`, etc.) to new stable IDs
    /// matched by `baseID` + left-to-right position across `selectedMainBarIDs`, `mainBarOrderIDs`,
    /// `secondaryBarOrderIDs`, and `allAppsOrderIDs`.
    @discardableResult
    static func migrateMultiIconIDs(
        in state: inout MultiIconLayoutSnapshot,
        scannedCandidates: [ScannedMultiIconCandidate]
    ) -> [String: String] {
        guard !scannedCandidates.isEmpty else { return [:] }

        var grouped: [String: [ScannedMultiIconCandidate]] = [:]
        for candidate in scannedCandidates where !candidate.baseID.isEmpty {
            grouped[candidate.baseID, default: []].append(candidate)
        }

        var appliedMapping: [String: String] = [:]

        for baseID in grouped.keys.sorted() {
            guard !state.migratedBaseIDs.contains(baseID),
                  let group = grouped[baseID],
                  group.count >= 2 else {
                continue
            }

            let sortedNew = group.sorted { a, b in
                if (a.minX != nil) != (b.minX != nil) {
                    return a.minX != nil
                }
                if let ax = a.minX, let bx = b.minX, abs(ax - bx) > 0.5 {
                    return ax < bx
                }
                if a.axChildIndex != b.axChildIndex {
                    return a.axChildIndex < b.axChildIndex
                }
                return a.id < b.id
            }

            var newOrderedIDs: [String] = []
            var newIDSet = Set<String>()
            for entry in sortedNew where newIDSet.insert(entry.id).inserted {
                newOrderedIDs.append(entry.id)
            }
            guard newOrderedIDs.count >= 2 else { continue }

            // Collect all saved IDs belonging to `baseID` with appearance rank
            var savedAppearanceOrder: [String] = []
            var savedSet = Set<String>()
            let sources: [[String]] = [
                state.allAppsOrderIDs,
                state.mainBarOrderIDs,
                state.secondaryBarOrderIDs,
                state.selectedMainBarIDs.sorted()
            ]
            for list in sources {
                for id in list where belongsToBaseID(id, baseID: baseID) {
                    if savedSet.insert(id).inserted {
                        savedAppearanceOrder.append(id)
                    }
                }
            }

            guard !savedAppearanceOrder.isEmpty else { continue }

            if savedAppearanceOrder.allSatisfy({ newIDSet.contains($0) }) {
                state.migratedBaseIDs.insert(baseID)
                continue
            }

            let allAppsRank: [String: Int] = Dictionary(
                uniqueKeysWithValues: state.allAppsOrderIDs.enumerated().map { ($0.element, $0.offset) }
            )
            let appearanceRank: [String: Int] = Dictionary(
                uniqueKeysWithValues: savedAppearanceOrder.enumerated().map { ($0.element, $0.offset) }
            )

            let orderedSaved = savedAppearanceOrder.sorted { a, b in
                if let ra = allAppsRank[a], let rb = allAppsRank[b], ra != rb {
                    return ra < rb
                }
                let hintA = legacyPositionalHint(for: a, baseID: baseID)
                let hintB = legacyPositionalHint(for: b, baseID: baseID)
                if let ha = hintA, let hb = hintB, ha != hb {
                    return ha < hb
                }
                if (hintA != nil) != (hintB != nil) {
                    return hintA != nil
                }
                return (appearanceRank[a] ?? 0) < (appearanceRank[b] ?? 0)
            }

            let unmatchedOld = orderedSaved.filter { !newIDSet.contains($0) }
            let unmatchedNew = newOrderedIDs.filter { !savedSet.contains($0) }

            var localMap: [String: String] = [:]
            for (oldID, newID) in zip(unmatchedOld, unmatchedNew) where oldID != newID {
                localMap[oldID] = newID
                appliedMapping[oldID] = newID
            }

            if !localMap.isEmpty {
                var updatedSelected = state.selectedMainBarIDs
                for (oldID, newID) in localMap {
                    if updatedSelected.remove(oldID) != nil {
                        updatedSelected.insert(newID)
                    }
                }
                state.selectedMainBarIDs = updatedSelected
                state.mainBarOrderIDs = remapAndDeduplicate(state.mainBarOrderIDs, using: localMap)
                state.secondaryBarOrderIDs = remapAndDeduplicate(state.secondaryBarOrderIDs, using: localMap)
                state.allAppsOrderIDs = remapAndDeduplicate(state.allAppsOrderIDs, using: localMap)
            }

            state.migratedBaseIDs.insert(baseID)
        }

        return appliedMapping
    }

    private static func legacyPositionalHint(for id: String, baseID: String) -> Int? {
        if id == baseID {
            return 0
        }
        let itemPrefix = baseID + "#item-"
        if id.hasPrefix(itemPrefix), let idx = Int(id.dropFirst(itemPrefix.count)) {
            return idx
        }
        let posPrefix = baseID + "#pos-"
        if id.hasPrefix(posPrefix), let idx = Int(id.dropFirst(posPrefix.count)) {
            return idx
        }
        return nil
    }

    private static func remapAndDeduplicate(_ array: [String], using mapping: [String: String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(array.count)
        for id in array {
            let mapped = mapping[id] ?? id
            if seen.insert(mapped).inserted {
                out.append(mapped)
            }
        }
        return out
    }
}
