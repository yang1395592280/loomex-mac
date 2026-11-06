import AppKit
import Foundation

struct LaunchItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case app, folder }
    var id: String
    var kind: Kind
    var name: String
    var path: String?
    var children: [LaunchItem]

    static func app(path: String, name: String) -> LaunchItem {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return LaunchItem(id: canonicalPath, kind: .app, name: name, path: canonicalPath, children: [])
    }

    static func folder(name: String, apps: [LaunchItem]) -> LaunchItem {
        LaunchItem(id: UUID().uuidString, kind: .folder, name: name, path: nil, children: apps)
    }
}

struct LaunchLayout: Codable, Equatable {
    var version = 1
    var pages: [[LaunchItem]] = [[]]
    var defaultUtilityGroupingVersion: Int?
    static let pageCapacity = 35

    var apps: [LaunchItem] {
        pages.flatMap { $0 }.flatMap { $0.kind == .folder ? $0.children : [$0] }
    }

    func item(id: String) -> LaunchItem? {
        for item in pages.flatMap({ $0 }) {
            if item.id == id { return item }
            if let child = item.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    func search(_ query: String) -> [LaunchItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return apps.filter { app in
            terms.allSatisfy { term in
                app.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                URL(fileURLWithPath: app.path ?? "").deletingPathExtension().lastPathComponent
                    .range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    mutating func extract(id: String) -> LaunchItem? {
        for page in pages.indices {
            for index in pages[page].indices {
                if pages[page][index].id == id { return pages[page].remove(at: index) }
                if let child = pages[page][index].children.firstIndex(where: { $0.id == id }) {
                    return pages[page][index].children.remove(at: child)
                }
            }
        }
        return nil
    }

    mutating func normalize() {
        for page in pages.indices {
            pages[page] = pages[page].compactMap { item in
                guard item.kind == .folder else { return item }
                if item.children.isEmpty { return nil }
                return item.children.count == 1 ? item.children[0] : item
            }
        }
        var page = 0
        while page < pages.count {
            if pages[page].count > Self.pageCapacity {
                let overflow = Array(pages[page].dropFirst(Self.pageCapacity))
                pages[page] = Array(pages[page].prefix(Self.pageCapacity))
                if page + 1 == pages.count { pages.append([]) }
                pages[page + 1].insert(contentsOf: overflow, at: 0)
            }
            page += 1
        }
        pages.removeAll(where: \.isEmpty)
        if pages.isEmpty { pages = [[]] }
    }

    mutating func applyDefaultUtilityGrouping() {
        // A missing marker also covers 1.0 layouts. Never pull manually moved apps back on later scans.
        guard defaultUtilityGroupingVersion == nil, !apps.isEmpty else { return }
        defaultUtilityGroupingVersion = 1
        let utilities = pages.flatMap { $0 }.filter(LegacyUtilityGrouping.contains)
        guard !utilities.isEmpty else { return }
        let existingOther = pages.flatMap { $0 }.first {
            $0.kind == .folder && ["其他", "Other"].contains($0.name)
        }
        guard existingOther != nil || utilities.count > 1 else { return }
        let utilityIDs = Set(utilities.map(\.id))
        let firstPage = pages.firstIndex { $0.contains { utilityIDs.contains($0.id) } }!
        let firstIndex = pages[firstPage].firstIndex { utilityIDs.contains($0.id) }!
        for page in pages.indices {
            pages[page].removeAll { utilityIDs.contains($0.id) }
        }
        if let otherID = existingOther?.id {
            for page in pages.indices {
                if let index = pages[page].firstIndex(where: { $0.id == otherID }) {
                    pages[page][index].children.append(contentsOf: utilities)
                    return
                }
            }
        } else {
            pages[firstPage].insert(.folder(name: "其他", apps: utilities), at: firstIndex)
        }
    }

    func validate() throws {
        guard version == 1 else { throw LayoutError.invalid("布局版本不受支持。") }
        guard !pages.isEmpty else { throw LayoutError.invalid("布局缺少页面。") }
        var ids = Set<String>()
        var paths = Set<String>()
        for page in pages {
            guard page.count <= Self.pageCapacity else { throw LayoutError.invalid("页面图标数量超出限制。") }
            for item in page {
                guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(item.id).inserted else { throw LayoutError.invalid("布局包含重复或无效项目。") }
                if item.kind == .app {
                    try Self.validateApp(item, paths: &paths)
                } else {
                    guard item.path == nil, !item.children.isEmpty else { throw LayoutError.invalid("文件夹内容无效。") }
                    for app in item.children {
                        guard ids.insert(app.id).inserted else { throw LayoutError.invalid("布局包含重复应用。") }
                        try Self.validateApp(app, paths: &paths)
                    }
                }
            }
        }
    }

    private static func validateApp(_ app: LaunchItem, paths: inout Set<String>) throws {
        guard app.kind == .app, app.children.isEmpty, let path = app.path,
              path.hasPrefix("/"), path.lowercased().hasSuffix(".app"),
              app.id == URL(fileURLWithPath: path).standardizedFileURL.path,
              paths.insert(path).inserted else { throw LayoutError.invalid("应用路径无效或重复。") }
    }
}

enum LayoutError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let text): return text }
    }
}

enum AppSortMode: String, CaseIterable {
    case nameAscending, nameDescending, addedOldest, addedNewest
    case createdOldest, createdNewest, modifiedOldest, modifiedNewest

    var title: String {
        switch self {
        case .nameAscending: return "名称：正序"
        case .nameDescending: return "名称：倒序"
        case .addedOldest: return "添加时间：从早到晚"
        case .addedNewest: return "添加时间：从晚到早"
        case .createdOldest: return "创建时间：从早到晚"
        case .createdNewest: return "创建时间：从晚到早"
        case .modifiedOldest: return "修改时间：从早到晚"
        case .modifiedNewest: return "修改时间：从晚到早"
        }
    }
}

struct AppSortMetadata {
    var added: Date?
    var created: Date?
    var modified: Date?

    static func read(apps: [LaunchItem]) -> [String: Self] {
        var result: [String: Self] = [:]
        for app in apps {
            guard let path = app.path,
                  let values = try? URL(fileURLWithPath: path).resourceValues(forKeys:
                    [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]) else { continue }
            result[app.id] = Self(added: values.addedToDirectoryDate ?? values.creationDate,
                                  created: values.creationDate, modified: values.contentModificationDate)
        }
        return result
    }
}

enum LayoutSorter {
    static func sorted(_ items: [LaunchItem], by mode: AppSortMode, metadata: [String: AppSortMetadata]) -> [LaunchItem] {
        // Read file metadata once before sorting, never from inside the comparator.
        var dates: [String: Date] = [:]
        for item in items {
            let members = item.kind == .folder ? item.children : [item]
            dates[item.id] = members.compactMap { member -> Date? in
                let time = metadata[member.id]
                switch mode {
                case .addedOldest, .addedNewest: return time?.added
                case .createdOldest, .createdNewest: return time?.created
                case .modifiedOldest, .modifiedNewest: return time?.modified
                default: return nil
                }
            }.max()
        }
        return items.sorted { lhs, rhs in
            if mode != .nameAscending && mode != .nameDescending {
                let left = dates[lhs.id], right = dates[rhs.id]
                if let left = left, let right = right, left != right {
                    return [.addedNewest, .createdNewest, .modifiedNewest].contains(mode) ? left > right : left < right
                }
                if (left == nil) != (right == nil) { return left != nil }
            }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return mode == .nameDescending ? order == .orderedDescending : order == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

private struct SortUndoSnapshot: Codable {
    var before: LaunchLayout
    var after: LaunchLayout
}

final class LayoutStore {
    private(set) var layout: LaunchLayout
    let fileURL: URL
    private let fileManager = FileManager.default
    private var sortUndoURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("sort-undo.json") }

    var canUndoSort: Bool {
        guard let data = try? Data(contentsOf: sortUndoURL),
              let snapshot = try? JSONDecoder().decode(SortUndoSnapshot.self, from: data) else { return false }
        return snapshot.after == layout && snapshot.before != layout
    }

    init(directory: URL) throws {
        fileURL = directory.appendingPathComponent("layout.json")
        if fileManager.fileExists(atPath: fileURL.path) {
            layout = try JSONDecoder().decode(LaunchLayout.self, from: Data(contentsOf: fileURL))
            try layout.validate()
        } else {
            layout = LaunchLayout()
        }
    }

    private func update(_ mutation: (inout LaunchLayout) throws -> Void) throws {
        var next = layout
        try mutation(&next)
        next.normalize()
        try next.validate()
        guard next != layout else { return }
        let data = try JSONEncoder.pretty.encode(next)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Preserve the previous valid file before the atomic replacement; failed writes keep memory unchanged.
        if fileManager.fileExists(atPath: fileURL.path) {
            let oldData = try Data(contentsOf: fileURL)
            try oldData.write(to: fileURL.appendingPathExtension("backup"), options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
        layout = next
    }

    func reconcile(apps: [LaunchItem]) throws {
        var catalog: [String: LaunchItem] = [:]
        for app in apps where app.kind == .app { catalog[app.id] = app }
        try update { next in
            for page in next.pages.indices {
                next.pages[page] = next.pages[page].compactMap { item in
                    if item.kind == .app { return catalog[item.id] }
                    var folder = item
                    folder.children = folder.children.compactMap { catalog[$0.id] }
                    return folder
                }
            }
            let existing = Set(next.apps.map(\.id))
            let additions = catalog.values.filter { !existing.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if next.pages.isEmpty { next.pages = [[]] }
            next.pages[next.pages.count - 1].append(contentsOf: additions)
            next.applyDefaultUtilityGrouping()
        }
    }

    func sort(by mode: AppSortMode, folderID: String? = nil, metadata: [String: AppSortMetadata] = [:]) throws {
        var sorted = layout
        if let folderID = folderID {
            for page in sorted.pages.indices {
                if let index = sorted.pages[page].firstIndex(where: { $0.id == folderID && $0.kind == .folder }) {
                    sorted.pages[page][index].children = LayoutSorter.sorted(sorted.pages[page][index].children, by: mode, metadata: metadata)
                }
            }
        } else {
            let items = LayoutSorter.sorted(sorted.pages.flatMap { $0 }, by: mode, metadata: metadata)
            sorted.pages = items.isEmpty ? [[]] : stride(from: 0, to: items.count, by: LaunchLayout.pageCapacity).map {
                Array(items[$0..<min($0 + LaunchLayout.pageCapacity, items.count)])
            }
        }
        try sorted.validate()
        guard sorted != layout else { return }
        try fileManager.createDirectory(at: sortUndoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(SortUndoSnapshot(before: layout, after: sorted)).write(to: sortUndoURL, options: .atomic)
        try update { $0 = sorted }
    }

    func undoLastSort() throws {
        let snapshot = try JSONDecoder().decode(SortUndoSnapshot.self, from: Data(contentsOf: sortUndoURL))
        guard snapshot.after == layout else { throw LayoutError.invalid("排序后布局已有其他改动，无法撤销旧排序。") }
        try snapshot.before.validate()
        try update { $0 = snapshot.before }
    }

    func move(id: String, toPage page: Int, before targetID: String?) throws {
        guard id != targetID else { return }
        try update { next in
            guard let item = next.extract(id: id) else { return }
            let destination = min(max(page, 0), next.pages.count)
            if destination == next.pages.count { next.pages.append([]) }
            let index = targetID.flatMap { target in next.pages[destination].firstIndex { $0.id == target } }
                ?? next.pages[destination].count
            next.pages[destination].insert(item, at: index)
        }
    }

    func group(id: String, with targetID: String) throws {
        guard id != targetID else { return }
        try update { next in
            guard next.item(id: id)?.kind == .app,
                  let target = next.pages.flatMap({ $0 }).first(where: { $0.id == targetID }),
                  let source = next.extract(id: id) else { return }
            for page in next.pages.indices {
                guard let index = next.pages[page].firstIndex(where: { $0.id == targetID }) else { continue }
                if target.kind == .folder {
                    next.pages[page][index].children.append(source)
                } else {
                    next.pages[page][index] = .folder(name: "文件夹", apps: [target, source])
                }
                return
            }
        }
    }

    func moveIntoFolder(id: String, folderID: String, before targetID: String? = nil) throws {
        guard id != targetID, id != folderID else { return }
        try update { next in
            guard next.item(id: id)?.kind == .app,
                  next.pages.flatMap({ $0 }).contains(where: { $0.id == folderID && $0.kind == .folder }),
                  let source = next.extract(id: id) else { return }
            for page in next.pages.indices {
                guard let folder = next.pages[page].firstIndex(where: { $0.id == folderID }) else { continue }
                let index = targetID.flatMap { id in next.pages[page][folder].children.firstIndex { $0.id == id } }
                    ?? next.pages[page][folder].children.count
                next.pages[page][folder].children.insert(source, at: index)
                return
            }
        }
    }

    func renameFolder(id: String, name: String) throws {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty else { return }
        try update { next in
            for page in next.pages.indices {
                if let index = next.pages[page].firstIndex(where: { $0.id == id && $0.kind == .folder }) {
                    next.pages[page][index].name = clean
                }
            }
        }
    }

    func ungroup(id: String) throws {
        try update { next in
            for page in next.pages.indices {
                guard let index = next.pages[page].firstIndex(where: { $0.id == id && $0.kind == .folder }) else { continue }
                let apps = next.pages[page][index].children
                next.pages[page].replaceSubrange(index...index, with: apps)
                return
            }
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum LegacyUtilityGrouping {
    // The protected system Utilities directory and the traditional secondary built-in apps.
    private static let additionalSystemApps: Set<String> = [
        "Automator.app", "Chess.app", "DVD Player.app", "Font Book.app", "Image Capture.app",
        "QuickTime Player.app", "Stickies.app", "TextEdit.app", "Time Machine.app"
    ]

    static func contains(_ item: LaunchItem) -> Bool {
        guard item.kind == .app, let path = item.path else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        if parent == "/System/Applications/Utilities" { return true }
        if parent == "/System/Applications" { return additionalSystemApps.contains(url.lastPathComponent) }
        if parent == "/Applications/Utilities" {
            return Bundle(url: url)?.bundleIdentifier?.hasPrefix("com.apple.") == true
        }
        return false
    }
}

enum AppScanner {
    static func scan(roots: [URL]? = nil, excluding bundleID: String? = nil) -> [LaunchItem] {
        let manager = FileManager.default
        let directories = roots ?? [
            URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var found: [String: LaunchItem] = [:]
        for root in directories {
            guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator {
                if iterator.level > 5 { iterator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                iterator.skipDescendants()
                guard let bundle = Bundle(url: url),
                      bundle.bundleIdentifier != bundleID,
                      (bundle.infoDictionary?["LSUIElement"] as? NSNumber)?.boolValue != true,
                      (bundle.infoDictionary?["LSBackgroundOnly"] as? NSNumber)?.boolValue != true else { continue }
                let localized = bundle.localizedInfoDictionary ?? [:]
                let raw = localized["CFBundleDisplayName"] as? String ?? localized["CFBundleName"] as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = LaunchItem.app(path: url.standardizedFileURL.path,
                                          name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
                found[item.id] = item
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
