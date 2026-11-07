import Foundation
import AppKit

var passed = 0
var failed = 0
let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("ClassicLaunchpadTests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: sandbox) }

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw LayoutError.invalid(message) }
}

func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(error)") }
}

func fresh(_ name: String, count: Int = 5) throws -> LayoutStore {
    let store = try LayoutStore(directory: sandbox.appendingPathComponent(name))
    try store.reconcile(apps: (0..<count).map { .app(path: "/Applications/App\($0).app", name: "App\($0)") })
    return store
}

func id(_ index: Int) -> String { "/Applications/App\(index).app" }

test("empty layout has one page and accepts empty scan") {
    let store = try fresh("empty", count: 0)
    try check(store.layout.pages == [[]], "Empty layout must be navigable")
}
test("36 apps produce 35 + 1 pages without loss") {
    let store = try fresh("capacity", count: 36)
    try check(store.layout.pages.map(\.count) == [35, 1], "Page capacity")
    try check(store.layout.apps.count == 36, "All apps remain")
}
test("rescan is idempotent and keeps manual order") {
    let store = try fresh("rescan")
    try store.move(id: id(4), toPage: 0, before: id(0))
    let expected = store.layout
    try store.reconcile(apps: expected.apps.reversed())
    try check(store.layout == expected, "Rescan must preserve order")
}
test("two app icons create a folder") {
    let store = try fresh("group")
    try store.group(id: id(0), with: id(1))
    let folder = store.layout.pages[0].first { $0.kind == .folder }
    try check(folder?.children.map(\.id) == [id(1), id(0)], "Folder content and order")
    try check(store.layout.apps.count == 5, "Grouping must not lose apps")
}
test("drop a third app onto a folder") {
    let store = try fresh("append")
    try store.group(id: id(0), with: id(1))
    let folder = store.layout.pages[0].first { $0.kind == .folder }!
    try store.group(id: id(2), with: folder.id)
    try check(store.layout.item(id: folder.id)?.children.count == 3, "Append to folder")
}
test("moving a child out collapses a one-app folder") {
    let store = try fresh("collapse")
    try store.group(id: id(0), with: id(1))
    try store.move(id: id(0), toPage: 0, before: id(4))
    try check(!store.layout.pages[0].contains { $0.kind == .folder }, "No singleton folder")
    try check(store.layout.apps.count == 5, "No app loss")
}
test("reorder children within a folder") {
    let store = try fresh("folderorder")
    try store.group(id: id(0), with: id(1))
    let folder = store.layout.pages[0].first { $0.kind == .folder }!
    try store.moveIntoFolder(id: id(2), folderID: folder.id)
    try store.moveIntoFolder(id: id(2), folderID: folder.id, before: id(1))
    try check(store.layout.item(id: folder.id)?.children.map(\.id) == [id(2), id(1), id(0)], "Child order")
}
test("folder rename trims whitespace and refuses blank names") {
    let store = try fresh("rename")
    try store.group(id: id(0), with: id(1))
    let folder = store.layout.pages[0].first { $0.kind == .folder }!
    try store.renameFolder(id: folder.id, name: "  常用工具  ")
    try store.renameFolder(id: folder.id, name: "   ")
    try check(store.layout.item(id: folder.id)?.name == "常用工具", "Valid title remains")
}
test("ungroup restores every child") {
    let store = try fresh("ungroup")
    try store.group(id: id(0), with: id(1))
    let folder = store.layout.pages[0].first { $0.kind == .folder }!
    try store.ungroup(id: folder.id)
    try check(store.layout.apps.count == 5 && store.layout.pages[0].count == 5, "Ungroup lossless")
}
test("cross-page move creates a page and survives restart") {
    let store = try fresh("restart")
    try store.move(id: id(0), toPage: 1, before: nil)
    let loaded = try LayoutStore(directory: store.fileURL.deletingLastPathComponent())
    try check(loaded.layout == store.layout && loaded.layout.pages[1][0].id == id(0), "Persistence")
}
test("search finds nested apps, handles case and Chinese") {
    let store = try fresh("search")
    try store.reconcile(apps: store.layout.apps + [.app(path: "/Applications/Calculator.app", name: "计算器")])
    try store.group(id: id(0), with: id(1))
    try check(store.layout.search("app0").map(\.id) == [id(0)], "Search nested app")
    try check(store.layout.search("计算").first?.name == "计算器", "Chinese search")
    try check(store.layout.search("CALCULATOR").first?.name == "计算器", "Bundle filename search")
    try check(store.layout.search("nothing-here").isEmpty, "Empty results")
}
test("missing app removal keeps remaining folder contents") {
    let store = try fresh("remove")
    try store.group(id: id(0), with: id(1))
    try store.reconcile(apps: store.layout.apps.filter { $0.id != id(0) })
    try check(store.layout.apps.count == 4 && store.layout.item(id: id(1)) != nil, "Remaining child survives")
}
test("invalid drag targets and self drops are no-ops") {
    let store = try fresh("invalid")
    let original = store.layout
    try store.group(id: id(0), with: "missing")
    try store.group(id: id(0), with: id(0))
    try store.moveIntoFolder(id: id(0), folderID: "missing")
    try store.move(id: "missing", toPage: 0, before: nil)
    try check(store.layout == original, "Invalid drag must not remove source")
}
test("nested folder grouping is rejected") {
    let store = try fresh("nested")
    try store.group(id: id(0), with: id(1))
    let folder = store.layout.pages[0].first { $0.kind == .folder }!
    let expected = store.layout
    try store.group(id: folder.id, with: id(2))
    try check(store.layout == expected, "No nested folders")
}
test("previous valid layout is backed up") {
    let store = try fresh("backup")
    let expected = store.layout
    try store.move(id: id(4), toPage: 0, before: id(0))
    let backup = try JSONDecoder().decode(LaunchLayout.self, from: Data(contentsOf: store.fileURL.appendingPathExtension("backup")))
    try check(backup == expected, "Previous valid version")
}
test("corrupt layout is refused without overwriting") {
    let directory = sandbox.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("layout.json")
    let data = Data("{bad json".utf8)
    try data.write(to: url)
    var refused = false
    do { _ = try LayoutStore(directory: directory) } catch { refused = true }
    let preserved = try Data(contentsOf: url)
    try check(refused && preserved == data, "Corrupt data must remain untouched")
}
test("write failure does not update memory") {
    let blocked = sandbox.appendingPathComponent("blocked")
    try Data("not a directory".utf8).write(to: blocked)
    let store = try LayoutStore(directory: blocked)
    let expected = store.layout
    var refused = false
    do { try store.reconcile(apps: [.app(path: id(0), name: "App0")]) } catch { refused = true }
    try check(refused && store.layout == expected, "Failed save must not mutate memory")
}
test("duplicate app paths are rejected when loading") {
    var invalid = LaunchLayout()
    let app = LaunchItem.app(path: id(0), name: "App0")
    invalid.pages = [[app, app]]
    var refused = false
    do { try invalid.validate() } catch { refused = true }
    try check(refused, "Duplicate identifiers refused")
}
test("hundreds of moves and groups preserve the app set") {
    let store = try fresh("stress", count: 100)
    let expected = Set(store.layout.apps.map(\.id))
    for iteration in 0..<300 {
        let apps = store.layout.apps
        let source = apps[(iteration * 17) % apps.count]
        if iteration % 3 == 0 {
            let target = store.layout.pages.flatMap { $0 }[(iteration * 13) % store.layout.pages.flatMap { $0 }.count]
            try store.group(id: source.id, with: target.id)
        } else { try store.move(id: source.id, toPage: iteration % 4, before: nil) }
        try store.layout.validate()
        try check(Set(store.layout.apps.map(\.id)) == expected, "Stress app-set invariant")
    }
}
test("scanner includes GUI apps and excludes helpers and nested bundles") {
    let root = sandbox.appendingPathComponent("scan")
    func bundle(_ relative: String, helper: Bool = false) throws {
        let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": relative, "CFBundleName": "Test", "CFBundlePackageType": "APPL", "LSUIElement": helper]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    try bundle("Visible.app")
    try bundle("Visible.app/Contents/Helpers/Nested.app")
    try bundle("Helper.app", helper: true)
    try bundle("Tools/Other.app")
    let apps = AppScanner.scan(roots: [root])
    try check(apps.count == 2 && !apps.contains { $0.path?.contains("Nested.app") == true }, "Only launchable top-level apps")
}

let systemTerminal = LaunchItem.app(path: "/System/Applications/Utilities/Terminal.app", name: "终端")
let systemConsole = LaunchItem.app(path: "/System/Applications/Utilities/Console.app", name: "控制台")
let systemDiskUtility = LaunchItem.app(path: "/System/Applications/Utilities/Disk Utility.app", name: "磁盘工具")
let systemNotes = LaunchItem.app(path: "/System/Applications/Notes.app", name: "备忘录")

test("default Other groups system utilities and leaves common and third-party apps outside") {
    let store = try fresh("default-other", count: 0)
    let textEdit = LaunchItem.app(path: "/System/Applications/TextEdit.app", name: "文本编辑")
    let thirdParty = LaunchItem.app(path: "/Applications/Utilities/ThirdParty.app", name: "第三方工具")
    try store.reconcile(apps: [systemTerminal, systemConsole, systemDiskUtility, textEdit, systemNotes, thirdParty])
    let other = store.layout.pages.flatMap { $0 }.first { $0.kind == .folder && $0.name == "其他" }
    try check(Set(other?.children.map(\.id) ?? []) == Set([systemTerminal.id, systemConsole.id, systemDiskUtility.id, textEdit.id]), "Expected legacy tools in Other")
    let top = store.layout.pages.flatMap { $0 }
    try check(top.contains { $0.id == systemNotes.id } && top.contains { $0.id == thirdParty.id }, "Common and third-party apps stay outside")
    try check(store.layout.apps.count == 6, "Grouping must keep every app")
}
test("1.0 layout upgrade groups top-level utilities while preserving user folders and order") {
    let directory = sandbox.appendingPathComponent("upgrade-other")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let custom = LaunchItem.folder(name: "我的工具", apps: [systemDiskUtility, systemConsole])
    var old = LaunchLayout()
    old.pages = [[systemNotes, custom, systemTerminal,
                  .app(path: "/System/Applications/Utilities/System Information.app", name: "系统信息")]]
    var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder.pretty.encode(old)) as! [String: Any]
    oldJSON.removeValue(forKey: "defaultUtilityGroupingVersion")
    let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
    try oldData.write(to: directory.appendingPathComponent("layout.json"))
    let store = try LayoutStore(directory: directory)
    try store.reconcile(apps: old.apps)
    try check(store.layout.pages[0].prefix(2).map(\.id) == [systemNotes.id, custom.id], "Preserve non-tool order")
    try check(store.layout.item(id: custom.id) == custom, "User folder content must remain intact")
    try check(store.layout.pages[0].last?.name == "其他", "Top-level tools are grouped on upgrade")
    let backupData = try Data(contentsOf: directory.appendingPathComponent("layout.json.backup"))
    try check(backupData == oldData, "Keep original 1.0 layout backup")
}
test("reopen and rescan preserve a utility manually moved out of Other") {
    let store = try fresh("manual-other", count: 0)
    let catalog = [systemTerminal, systemConsole, systemDiskUtility, systemNotes]
    try store.reconcile(apps: catalog)
    try check(store.layout.pages.flatMap { $0 }.contains { $0.kind == .folder && $0.name == "其他" }, "Other must exist before testing manual changes")
    try store.move(id: systemTerminal.id, toPage: 0, before: systemNotes.id)
    let expected = store.layout
    let reopened = try LayoutStore(directory: store.fileURL.deletingLastPathComponent())
    try reopened.reconcile(apps: catalog)
    try check(reopened.layout == expected, "No forced regroup after manual changes or restart")
}
test("existing Other is reused and manual rename or dissolve is not undone") {
    let directory = sandbox.appendingPathComponent("existing-other")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let other = LaunchItem.folder(name: "其他", apps: [systemTerminal, systemConsole])
    var old = LaunchLayout(); old.pages = [[other, systemDiskUtility, systemNotes]]
    try JSONEncoder.pretty.encode(old).write(to: directory.appendingPathComponent("layout.json"))
    let store = try LayoutStore(directory: directory)
    try store.reconcile(apps: old.apps)
    try check(store.layout.pages.flatMap { $0 }.filter { $0.kind == .folder }.count == 1, "Do not create duplicate Other folders")
    try check(store.layout.item(id: other.id)?.children.count == 3, "Append top-level utility to existing Other")
    try store.renameFolder(id: other.id, name: "工具")
    try store.reconcile(apps: old.apps)
    try check(store.layout.item(id: other.id)?.name == "工具", "Respect custom folder title")
    try store.ungroup(id: other.id)
    let expected = store.layout
    try store.reconcile(apps: old.apps)
    try check(store.layout == expected, "Do not recreate dissolved folder")
}
test("utility grouping across pages preserves capacity and the complete app set") {
    let directory = sandbox.appendingPathComponent("multipage-other")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var old = LaunchLayout()
    old.pages = [Array((0..<34).map { LaunchItem.app(path: id($0), name: "App\($0)") }) + [systemTerminal],
                 [systemConsole, systemDiskUtility, systemNotes]]
    try JSONEncoder.pretty.encode(old).write(to: directory.appendingPathComponent("layout.json"))
    let store = try LayoutStore(directory: directory)
    try store.reconcile(apps: old.apps)
    try store.layout.validate()
    try check(Set(store.layout.apps.map(\.id)) == Set(old.apps.map(\.id)), "No cross-page app loss or duplication")
    try check(store.layout.pages[0].last?.name == "其他" && store.layout.pages[1].map(\.id) == [systemNotes.id], "Other replaces the first grouped tool position")
}

test("held left drag advances a page and held right drag returns") {
    var left = BackgroundPageGesture(start: CGPoint(x: 700, y: 300))
    left.update(to: CGPoint(x: 350, y: 310))
    try check(left.destinationPage(from: 0, count: 3, width: 1000) == 1, "Left drag advances")
    var right = BackgroundPageGesture(start: CGPoint(x: 350, y: 300))
    right.update(to: CGPoint(x: 700, y: 295))
    try check(right.destinationPage(from: 1, count: 3, width: 1000) == 0, "Right drag returns")
}
test("short drag snaps back without becoming a click") {
    var gesture = BackgroundPageGesture(start: CGPoint(x: 500, y: 300))
    gesture.update(to: CGPoint(x: 470, y: 301))
    try check(gesture.destinationPage(from: 1, count: 3, width: 1000) == 1 && !gesture.isClick, "Short drag neither flips nor clicks")
}
test("vertical drag stays vertical even if it later moves sideways") {
    var gesture = BackgroundPageGesture(start: CGPoint(x: 500, y: 300))
    gesture.update(to: CGPoint(x: 510, y: 500))
    gesture.update(to: CGPoint(x: 900, y: 520))
    try check(gesture.horizontalOffset == 0 && gesture.destinationPage(from: 1, count: 3, width: 1000) == 1, "Vertical gesture must not flip pages")
}
test("drag out and back cancels paging and cannot dismiss as a click") {
    var gesture = BackgroundPageGesture(start: CGPoint(x: 500, y: 850))
    gesture.update(to: CGPoint(x: 100, y: 850))
    gesture.update(to: CGPoint(x: 500, y: 850))
    try check(gesture.destinationPage(from: 1, count: 3, width: 1000) == 1 && !gesture.isClick, "Returning to start is a cancelled drag")
    try check(!LauncherPointerRegions.shouldDismiss(gesture, size: CGSize(width: 1000, height: 900), height: 64), "Cancelled drag in bottom band must not dismiss")
}
test("first and last page drags never wrap or create pages") {
    var gesture = BackgroundPageGesture(start: CGPoint(x: 500, y: 300))
    gesture.update(to: CGPoint(x: 900, y: 300))
    try check(gesture.destinationPage(from: 0, count: 3, width: 1000) == 0, "First page clamps")
    gesture = BackgroundPageGesture(start: CGPoint(x: 500, y: 300))
    gesture.update(to: CGPoint(x: 100, y: 300))
    try check(gesture.destinationPage(from: 2, count: 3, width: 1000) == 2, "Last page clamps")
    try check(gesture.destinationPage(from: 0, count: 1, width: 1000) == 0, "Single page remains stable")
}
test("bottom dismissal accepts left and right clicks with small pointer jitter") {
    for x: CGFloat in [20, 980] {
        var gesture = BackgroundPageGesture(start: CGPoint(x: x, y: 870))
        gesture.update(to: CGPoint(x: x + 2, y: 871))
        try check(LauncherPointerRegions.shouldDismiss(gesture, size: CGSize(width: 1000, height: 900), height: 64), "Dock-side click dismisses")
    }
    let ordinary = BackgroundPageGesture(start: CGPoint(x: 20, y: 300))
    try check(!LauncherPointerRegions.shouldDismiss(ordinary, size: CGSize(width: 1000, height: 900), height: 64), "Main area click keeps launcher open")
}
test("drag into or within bottom dismissal strip never closes the launcher") {
    let size = CGSize(width: 1000, height: 900)
    var entering = BackgroundPageGesture(start: CGPoint(x: 20, y: 700))
    entering.update(to: CGPoint(x: 20, y: 870))
    try check(!LauncherPointerRegions.shouldDismiss(entering, size: size, height: 64), "Moving into strip must not dismiss")
    var sideways = BackgroundPageGesture(start: CGPoint(x: 20, y: 870))
    sideways.update(to: CGPoint(x: 300, y: 870))
    try check(!LauncherPointerRegions.shouldDismiss(sideways, size: size, height: 64), "Bottom strip drag must not dismiss")
}
test("small pointer jitter still activates an app icon") {
    var gesture = TilePointerGesture(start: CGPoint(x: 50, y: 50))
    gesture.update(to: CGPoint(x: 56, y: 54))
    try check(!gesture.beginDragIfNeeded(allowsDrag: true), "Minor hand jitter must not start a drag")
    try check(gesture.shouldActivate(at: CGPoint(x: 56, y: 54), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), allowsDrag: true), "Release after small jitter activates the icon")
}
test("intentional tile drag starts at the forgiving threshold and suppresses launch") {
    var gesture = TilePointerGesture(start: CGPoint(x: 50, y: 50))
    gesture.update(to: CGPoint(x: 60, y: 50))
    try check(gesture.beginDragIfNeeded(allowsDrag: true), "Ten-point movement starts item drag")
    try check(!gesture.shouldActivate(at: CGPoint(x: 60, y: 50), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), allowsDrag: true), "Dragged icon must not launch on release")
}
test("releasing outside a tile does not launch it") {
    var gesture = TilePointerGesture(start: CGPoint(x: 50, y: 50))
    gesture.update(to: CGPoint(x: 120, y: 50))
    try check(!gesture.shouldActivate(at: CGPoint(x: 120, y: 50), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), allowsDrag: true), "Release outside tile does not activate")
}
test("search result tiles remain clickable when item dragging is disabled") {
    var gesture = TilePointerGesture(start: CGPoint(x: 50, y: 50))
    gesture.update(to: CGPoint(x: 70, y: 50))
    try check(!gesture.beginDragIfNeeded(allowsDrag: false), "Search result does not start reordering")
    try check(gesture.shouldActivate(at: CGPoint(x: 70, y: 50), bounds: CGRect(x: 0, y: 0, width: 100, height: 100), allowsDrag: false), "Search result still activates")
}
test("bottom strip geometry follows Dock height and handles offset screens") {
    let screen = CGRect(x: 3008, y: -200, width: 1000, height: 900)
    let visible = CGRect(x: 3008, y: -120, width: 1000, height: 780)
    try check(LauncherPointerRegions.bottomStripHeight(screenFrame: screen, visibleFrame: visible) == 80, "Use reserved Dock height, not global origin")
    try check(LauncherPointerRegions.bottomStripHeight(screenFrame: screen, visibleFrame: screen) == 48, "Auto-hidden Dock retains a small bottom band")
    try check(!LauncherPointerRegions.isInBottomStrip(CGPoint(x: -1, y: 880), size: screen.size, height: 80), "Outside window does not count")
}

test("page motion style persists independently of app layout") {
    let url = sandbox.appendingPathComponent("preferences.json")
    try check(PageMotionPreferences.load(from: url).style == .classic, "Missing preferences use classic")
    for style in PageAnimationStyle.allCases {
        try PageMotionPreferences(style: style).save(to: url)
        try check(PageMotionPreferences.load(from: url).style == style, "Selected effect survives reopening")
    }
}
test("unknown or malformed motion preferences fall back to classic") {
    let url = sandbox.appendingPathComponent("unknown-preferences.json")
    for json in ["{\"style\":\"future-effect\"}", "invalid"] {
        try Data(json.utf8).write(to: url)
        try check(PageMotionPreferences.load(from: url).style == .classic, "Invalid preference cannot block launch")
    }
}

test("name sorting uses natural numbers and supports reverse order") {
    let items = [LaunchItem.app(path: id(10), name: "App10"), .app(path: id(2), name: "App2"), .app(path: id(1), name: "App1")]
    try check(LayoutSorter.sorted(items, by: .nameAscending, metadata: [:]).map(\.name) == ["App1", "App2", "App10"], "Natural ascending names")
    try check(LayoutSorter.sorted(items, by: .nameDescending, metadata: [:]).map(\.name) == ["App10", "App2", "App1"], "Natural descending names")
}
test("all time sorts use their own field in both directions and place missing dates last") {
    let items = (0..<4).map { LaunchItem.app(path: id($0), name: "App\($0)") }
    let metadata = [id(0): AppSortMetadata(added: Date(timeIntervalSince1970: 30), created: Date(timeIntervalSince1970: 20), modified: Date(timeIntervalSince1970: 40)),
                    id(1): AppSortMetadata(added: Date(timeIntervalSince1970: 40), created: Date(timeIntervalSince1970: 10), modified: Date(timeIntervalSince1970: 20)),
                    id(2): AppSortMetadata(added: Date(timeIntervalSince1970: 20), created: Date(timeIntervalSince1970: 30), modified: Date(timeIntervalSince1970: 10))]
    let expectations: [(AppSortMode, [Int])] = [(.addedOldest, [2,0,1,3]), (.addedNewest, [1,0,2,3]),
        (.createdOldest, [1,0,2,3]), (.createdNewest, [2,0,1,3]), (.modifiedOldest, [2,1,0,3]), (.modifiedNewest, [0,1,2,3])]
    for (mode, expected) in expectations {
        try check(LayoutSorter.sorted(items, by: mode, metadata: metadata).map(\.id) == expected.map(id), "Time field and direction: \(mode)")
    }
}
test("equal times have deterministic name and identity tie breakers") {
    let items = [LaunchItem.app(path: id(1), name: "Same"), .app(path: id(0), name: "Same")]
    let time = AppSortMetadata(added: Date(timeIntervalSince1970: 10))
    for mode in AppSortMode.allCases {
        try check(LayoutSorter.sorted(items, by: mode, metadata: [id(0): time, id(1): time]).map(\.id) == [id(0), id(1)], "Stable ties")
    }
}
test("global sort repaginates without changing folders or losing apps") {
    let store = try fresh("sort-pages", count: 40)
    try store.group(id: id(1), with: id(0))
    let original = store.layout
    let folder = original.pages.flatMap { $0 }.first { $0.kind == .folder }!
    try store.sort(by: .nameDescending)
    try store.layout.validate()
    try check(store.layout.pages.map(\.count) == [35, 4], "Repaginate at capacity")
    try check(store.layout.item(id: folder.id) == folder, "Folder members and their order remain intact")
    try check(Set(store.layout.apps.map(\.id)) == Set(original.apps.map(\.id)), "Preserve complete app set")
}
test("folder sort affects only that folder and dates use newest member") {
    let store = try fresh("sort-folder", count: 5)
    try store.group(id: id(1), with: id(0))
    let original = store.layout
    let folder = original.pages[0].first { $0.kind == .folder }!
    try store.sort(by: .nameDescending, folderID: folder.id)
    try check(store.layout.pages.flatMap { $0 }.map(\.id) == original.pages.flatMap { $0 }.map(\.id), "Outer order unchanged")
    try check(store.layout.item(id: folder.id)?.children.map(\.id) == [id(1),id(0)], "Sort folder children")
    let dates = [id(0): AppSortMetadata(added: Date(timeIntervalSince1970: 1)), id(1): AppSortMetadata(added: Date(timeIntervalSince1970: 30)), id(2): AppSortMetadata(added: Date(timeIntervalSince1970: 20))]
    let sorted = LayoutSorter.sorted([folder, .app(path: id(2), name: "App2")], by: .addedNewest, metadata: dates)
    try check(sorted.first?.id == folder.id, "Folder time is newest member")
}
test("undo sort survives restart and restores original page breaks") {
    let store = try fresh("sort-undo", count: 40)
    try store.move(id: id(39), toPage: 0, before: id(0))
    let original = store.layout
    try store.sort(by: .nameAscending)
    try check(store.canUndoSort, "Undo becomes available")
    let reopened = try LayoutStore(directory: store.fileURL.deletingLastPathComponent())
    try check(reopened.canUndoSort, "Undo survives restart")
    try reopened.undoLastSort()
    try check(reopened.layout == original && !reopened.canUndoSort, "Restore exact pages and disable repeated undo")
}
test("manual edits invalidate old sort undo and failed undo preserves layout") {
    let store = try fresh("sort-undo-stale")
    try store.sort(by: .nameDescending)
    try store.move(id: id(0), toPage: 0, before: id(4))
    let expected = store.layout
    try check(!store.canUndoSort, "Do not undo later manual work")
    var rejected = false
    do { try store.undoLastSort() } catch { rejected = true }
    try check(rejected && store.layout == expected, "Stale undo is rejected without changing layout")
}

test("selected motion style animates even when system reduce motion is enabled") {
    for style in PageAnimationStyle.allCases {
        let preferences = PageMotionPreferences(style: style)
        try check(preferences.animationDuration(systemReduceMotion: true) == style.duration, "Explicit per-app animation stays enabled")
        let following = PageMotionPreferences(style: style, followSystemReduceMotion: true)
        try check(following.animationDuration(systemReduceMotion: true) == 0, "Opt-in system preference is respected")
        try check(following.animationDuration(systemReduceMotion: false) == style.duration, "System without reduction keeps style")
    }
}
test("1.0.2 preferences retain selected style when upgrading animation policy") {
    let data = Data("{\"style\":\"smooth\"}".utf8)
    let preferences = try JSONDecoder().decode(PageMotionPreferences.self, from: data)
    try check(preferences.style == .smooth && !preferences.followSystemReduceMotion, "Old preferences migrate without resetting style")
    let url = sandbox.appendingPathComponent("reduce-motion-preferences.json")
    try PageMotionPreferences(style: .quick, followSystemReduceMotion: true).save(to: url)
    let reopened = PageMotionPreferences.load(from: url)
    try check(reopened.style == .quick && reopened.followSystemReduceMotion, "Both settings survive reopening")
}
test("time metadata reads real app directory and handles a missing app") {
    let directory = sandbox.appendingPathComponent("Metadata.app")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let app = LaunchItem.app(path: directory.path, name: "Metadata")
    let missing = LaunchItem.app(path: sandbox.appendingPathComponent("Missing.app").path, name: "Missing")
    let metadata = AppSortMetadata.read(apps: [app, missing])
    try check(metadata[app.id]?.created != nil && metadata[app.id]?.modified != nil && metadata[app.id]?.added != nil, "Read dates or added-date fallback")
    try check(metadata[missing.id] == nil, "Missing files do not block sorting")
}

test("every visible icon receives clicks across all five rows") {
    _ = NSApplication.shared
    let store = try fresh("icon-hit-regions", count: 70)
    let canvas = LaunchCanvas(store: store)
    let parent = NSView()
    parent.addSubview(canvas)
    for size in [NSSize(width: 1280, height: 800), NSSize(width: 3008, height: 1692)] {
        parent.frame = NSRect(origin: .zero, size: size)
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.layoutSubtreeIfNeeded()
        let page = canvas.subviews.compactMap { $0 as? PageContentView }.first { !$0.isHidden && $0.acceptsInput }!
        try check(page.tiles.count == 35, "Hit test must cover a full page")
        for (index, tile) in page.tiles.enumerated() {
            let center = NSPoint(x: tile.iconRect.midX, y: tile.iconRect.midY)
            let point = tile.convert(center, to: parent)
            let hit = parent.hitTest(point)
            try check(hit === tile, "Row \(index / 7 + 1) icon \(index % 7 + 1) \(tile.item.id) blocked by \((hit as? LaunchTile)?.item.id ?? String(describing: hit)) at \(point) / \(size)")
        }
    }
}

test("visible status text passes pointer input through to the background") {
    _ = NSApplication.shared
    let store = try fresh("empty-search-hit", count: 1)
    let canvas = LaunchCanvas(store: store)
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    parent.addSubview(canvas)
    canvas.frame = parent.bounds
    canvas.search.stringValue = "not-an-installed-app"
    canvas.refresh()
    canvas.layoutSubtreeIfNeeded()
    try check(!canvas.emptyLabel.isHidden && !canvas.emptyLabel.stringValue.isEmpty, "No-result message stays visible")
    let point = canvas.emptyLabel.convert(NSPoint(x: canvas.emptyLabel.bounds.midX, y: canvas.emptyLabel.bounds.midY), to: parent)
    let hit = parent.hitTest(point)
    try check(hit != nil && !(hit is NSTextField), "Status message must not swallow background gestures")
    canvas.search.stringValue = ""
    canvas.refresh()
    try check(canvas.emptyLabel.isHidden, "Status overlay disappears when icons return")
}

test("sparse background clicks dismiss while full pages only dismiss below the last row") {
    let size = CGSize(width: 1280, height: 800)
    for count in [0, 1, 7, 28, 34] {
        for point in [CGPoint(x: 20, y: 200), CGPoint(x: 1200, y: 500), CGPoint(x: 600, y: 700)] {
            let click = BackgroundPageGesture(start: point)
            try check(LauncherPointerRegions.shouldDismissBackground(click, size: size, itemCount: count, lastRowBottom: 650), "Sparse background dismisses at \(point)")
        }
    }
    try check(!LauncherPointerRegions.shouldDismissBackground(BackgroundPageGesture(start: CGPoint(x: 20, y: 400)), size: size, itemCount: 35, lastRowBottom: 650), "Full page retains main drag area")
    try check(LauncherPointerRegions.shouldDismissBackground(BackgroundPageGesture(start: CGPoint(x: 20, y: 670)), size: size, itemCount: 35, lastRowBottom: 650), "Full page bottom whitespace dismisses")
    for point in [CGPoint(x: 200, y: 500), CGPoint(x: 20, y: 201)] {
        var gesture = BackgroundPageGesture(start: CGPoint(x: 20, y: 500))
        gesture.update(to: point)
        gesture.update(to: gesture.start)
        try check(!LauncherPointerRegions.shouldDismissBackground(gesture, size: size, itemCount: 1, lastRowBottom: 650), "Dragging, including returning to origin, never dismisses")
    }
}

test("real background hit regions reach canvas and folder outside clicks return to grid") {
    _ = NSApplication.shared
    for count in [5, 35] {
        let store = try fresh("dismiss-hit-\(count)", count: count)
        let window = LaunchWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = LaunchCanvas(store: store)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        var dismissed = 0
        canvas.dismiss = { dismissed += 1 }
        func click(_ point: CGPoint) {
            let location = canvas.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        func hit(_ point: CGPoint) -> NSView? { canvas.hitTest(canvas.convert(point, to: canvas.superview)) }
        let main = CGPoint(x: 20, y: 300)
        try check(hit(main) === canvas, "Transparent background reaches canvas")
        click(main)
        try check(dismissed == (count < 35 ? 1 : 0), "Main area respects page fullness")
        let besideDots = CGPoint(x: canvas.dots.frame.minX + 5, y: canvas.dots.frame.midY)
        try check(hit(besideDots) === canvas, "Wide dot view does not swallow empty area")
        let page = canvas.subviews.compactMap { $0 as? PageContentView }.first { $0.acceptsInput && !$0.isHidden }!
        let bottom = CGPoint(x: 20, y: page.tiles.map { $0.frame.maxY }.max()! + 8)
        click(bottom)
        try check(dismissed == (count < 35 ? 2 : 1), "Whitespace immediately below icons dismisses")
        try check(hit(CGPoint(x: canvas.search.frame.midX, y: canvas.search.frame.midY)) !== canvas, "Search retains input")
        try store.group(id: id(0), with: id(1))
        canvas.refresh()
        canvas.activate(store.layout.pages[0].first { $0.kind == .folder }!)
        canvas.layoutSubtreeIfNeeded()
        let before = dismissed
        click(main)
        try check(dismissed == before && canvas.folderName.isHidden, "Folder outside click returns to grid without dismissing launcher")
    }
}

test("hidden resources remain released through refresh and rebuild on reopening") {
    _ = NSApplication.shared
    let store = try fresh("suspend-resources", count: 70)
    let canvas = LaunchCanvas(store: store)
    canvas.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    canvas.layoutSubtreeIfNeeded()
    _ = canvas.icons.image(for: store.layout.apps[0])
    try check(canvas.icons.count > 0, "Visible icon is cached")
    let expected = store.layout
    canvas.suspendResources()
    canvas.refresh()
    canvas.layoutSubtreeIfNeeded()
    try check(canvas.resourcesSuspended && canvas.icons.count == 0, "Hidden refresh cannot recreate icon cache")
    try check(!canvas.subviews.contains { $0 is PageContentView }, "Hidden pages and their backing layers are detached")
    canvas.resetForOpening()
    canvas.layoutSubtreeIfNeeded()
    let page = canvas.subviews.compactMap { $0 as? PageContentView }.first { $0.acceptsInput && !$0.isHidden }
    try check(!canvas.resourcesSuspended && page?.tiles.count == 35, "Reopening restores complete clickable page")
    try check(store.layout == expected, "Resource release does not alter layout")
}

test("wallpaper uses a bounded texture and can reload after resource release") {
    _ = NSApplication.shared
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 1800, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let url = sandbox.appendingPathComponent("wallpaper.png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    let wallpaper = WallpaperView(frame: NSRect(x: 0, y: 0, width: 3008, height: 1692))
    for _ in 0..<2 {
        try check(wallpaper.update(from: url), "Wallpaper decodes")
        try check(wallpaper.cachedPixelSize == CGSize(width: 1600, height: 900), "Texture is independent of 6K screen backing size")
        wallpaper.releaseContents()
        try check(wallpaper.cachedPixelSize == .zero && wallpaper.layer?.contents == nil, "Hidden wallpaper releases both image and layer")
    }
}

test("grid matches the original reference positions without losing icon hit targets") {
    _ = NSApplication.shared
    let store = try fresh("reference-geometry", count: 35)
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 3008, height: 1692))
    let canvas = LaunchCanvas(store: store)
    parent.addSubview(canvas)
    canvas.frame = parent.bounds
    canvas.layoutSubtreeIfNeeded()
    let page = canvas.subviews.compactMap { $0 as? PageContentView }.first { $0.acceptsInput && !$0.isHidden }!
    // Centers measured from the user-supplied 6016×3384 Launchpad image, expressed in screen points.
    for (index, expected) in [(0, CGPoint(x: 609, y: 266)), (6, CGPoint(x: 2399, y: 266)),
                              (14, CGPoint(x: 609, y: 829)), (34, CGPoint(x: 2399, y: 1393))] {
        let tile = page.tiles[index]
        let center = tile.convert(CGPoint(x: tile.iconRect.midX, y: tile.iconRect.midY), to: canvas)
        try check(abs(center.x - expected.x) < 2 && abs(center.y - expected.y) < 2, "Reference icon position \(index) at \(center)")
    }
    try check(abs(canvas.dots.frame.midY - 1554) < 2, "Page dots leave the original bottom margin")
    try check(!canvas.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "启动台选项" }, "Settings button does not alter the original surface")
}

test("classic search placeholder centers while the field remains editable and cancelable") {
    _ = NSApplication.shared
    let canvas = LaunchCanvas(store: try fresh("reference-search", count: 1))
    canvas.frame = NSRect(x: 0, y: 0, width: 3008, height: 1692)
    canvas.layoutSubtreeIfNeeded()
    let field = canvas.search
    try check(field.cell is NSSearchFieldCell, "AppKit search editing and cancel cell are retained")
    try check(field.isEditable && field.isSelectable, "Replacing the search cell must retain text editing")
    try check(field.frame == NSRect(x: 1379, y: 50, width: 250, height: 26), "Original search bounds")
    let button = field.centeredPlaceholderRects.icon
    let text = field.centeredPlaceholderRects.text
    try check(abs((button.minX + text.maxX) / 2 - field.bounds.midX) <= 2, "Empty search icon and text centered as a group")
    field.stringValue = "计算器"
    canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    try check(field.stringValue == "计算器", "Search refresh preserves entered text")
}

test("menu strip forwards background clicks to the grid instead of invisible system menus") {
    _ = NSApplication.shared
    for count in [5, 35] {
        let store = try fresh("menu-strip-\(count)", count: count)
        let main = LaunchWindow(contentRect: NSRect(x: 300, y: 200, width: 1280, height: 800),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        let canvas = LaunchCanvas(store: store)
        main.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        var dismissed = 0
        canvas.dismiss = { dismissed += 1 }
        let cover = MenuBarCoverWindow(contentRect: NSRect(x: 300, y: 976, width: 1280, height: 24),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        let view = MenuBarCoverView(frame: NSRect(x: 0, y: 0, width: 1280, height: 24))
        view.canvas = canvas
        cover.contentView = view
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 12), modifierFlags: [], timestamp: 0,
                                          windowNumber: cover.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        try check(dismissed == (count < 35 ? 1 : 0), "Top strip uses the page's ordinary background rule")
        try check(!cover.canBecomeKey && !cover.canBecomeMain, "Cover does not steal search or keyboard focus")
    }
}

test("bundle icon artwork is preferred and missing resources fall back to a usable icon") {
    _ = NSApplication.shared
    let app = sandbox.appendingPathComponent("RawArtwork.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "local.test.rawartwork", "CFBundlePackageType": "APPL", "CFBundleIconFile": "Original.png"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<8 { for x in 0..<8 {
        let offset = y * bitmap.bytesPerRow + x * 4
        bitmap.bitmapData![offset] = 255
        bitmap.bitmapData![offset + 1] = 0
        bitmap.bitmapData![offset + 2] = 0
        bitmap.bitmapData![offset + 3] = 255
    } }
    let artworkURL = resources.appendingPathComponent("Original.png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: artworkURL)
    let decoded = NSBitmapImageRep(data: try Data(contentsOf: artworkURL))!
    let inputCenter = decoded.colorAt(x: 4, y: 4)!.usingColorSpace(.deviceRGB)!
    try check(inputCenter.redComponent > 0.9 && inputCenter.alphaComponent > 0.9, "Fixture contains opaque red artwork")
    let cache = IconCache()
    let image = cache.image(for: .app(path: app.path, name: "RawArtwork"))
    let rendered = image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
    try check(rendered.pixelsWide == 256 && rendered.pixelsHigh == 256, "Raw icon renders into the bounded Retina cache")
    let center = rendered.colorAt(x: 128, y: 128)!.usingColorSpace(.deviceRGB)!
    try check(center.redComponent > 0.9 && center.greenComponent < 0.1 && center.blueComponent < 0.1 && center.alphaComponent > 0.9, "Original art center=\(center)")
    let fallback = cache.image(for: .app(path: sandbox.appendingPathComponent("MissingArtwork.app").path, name: "Fallback"))
    try check(!fallback.representations.isEmpty && fallback.size == NSSize(width: 128, height: 128), "No raw resource still yields a bounded icon")
}

test("classic product keeps its default and support override") {
    let base = sandbox.appendingPathComponent("identity-support")
    let custom = sandbox.appendingPathComponent("classic-custom")
    try check(LauncherProduct.classic.supportDirectory(environment: [:], applicationSupport: base)
        == base.appendingPathComponent("ClassicLaunchpad", isDirectory: true), "Existing default directory")
    try check(LauncherProduct.classic.supportDirectory(environment: ["CLASSIC_LAUNCHPAD_SUPPORT_DIR": custom.path],
        applicationSupport: base).path == custom.path, "Existing override remains a layout directory")
}
test("loomex ignores classic override and uses its own launch directory") {
    let base = sandbox.appendingPathComponent("identity-support")
    let directory = LauncherProduct.loomex.supportDirectory(environment: ["CLASSIC_LAUNCHPAD_SUPPORT_DIR": "/unused-classic"],
                                                           applicationSupport: base)
    try check(directory == base.appendingPathComponent("LoomexFlow/Launch", isDirectory: true), "Independent default root")
}
test("loomex support override is isolated beneath its launch subdirectory") {
    let custom = sandbox.appendingPathComponent("loomex-custom")
    let directory = LauncherProduct.loomex.supportDirectory(environment: ["LOOMEX_FLOW_SUPPORT_DIR": custom.path])
    try check(directory == custom.appendingPathComponent("Launch", isDirectory: true), "Root override retains module boundary")
}
test("new loomex store never imports an existing classic layout implicitly") {
    let base = sandbox.appendingPathComponent("no-implicit-import")
    let classic = try LayoutStore(directory: LauncherProduct.classic.supportDirectory(environment: [:], applicationSupport: base))
    try classic.reconcile(apps: [.app(path: "/Fixture/Old.app", name: "Old")])
    let loomex = try LayoutStore(directory: LauncherProduct.loomex.supportDirectory(environment: [:], applicationSupport: base))
    try check(loomex.layout.apps.isEmpty, "First Loomex launch begins independently")
    try check(!FileManager.default.fileExists(atPath: loomex.fileURL.path), "No copy or write during initialization")
}
test("loomex reconciliation and preferences leave classic files unchanged") {
    let base = sandbox.appendingPathComponent("two-products")
    let classic = try LayoutStore(directory: LauncherProduct.classic.supportDirectory(environment: [:], applicationSupport: base))
    try classic.reconcile(apps: [.app(path: "/Fixture/Original.app", name: "Original")])
    let classicPreferences = classic.fileURL.deletingLastPathComponent().appendingPathComponent("preferences.json")
    try PageMotionPreferences(style: .smooth).save(to: classicPreferences)
    let oldLayout = try Data(contentsOf: classic.fileURL)
    let oldPreferences = try Data(contentsOf: classicPreferences)
    let loomex = try LayoutStore(directory: LauncherProduct.loomex.supportDirectory(environment: [:], applicationSupport: base))
    try loomex.reconcile(apps: [.app(path: "/Fixture/New.app", name: "New")])
    try PageMotionPreferences(style: .quick).save(to: loomex.fileURL.deletingLastPathComponent().appendingPathComponent("preferences.json"))
    let currentLayout = try Data(contentsOf: classic.fileURL)
    let currentPreferences = try Data(contentsOf: classicPreferences)
    try check(currentLayout == oldLayout, "Classic layout bytes remain unchanged")
    try check(currentPreferences == oldPreferences, "Classic preferences bytes remain unchanged")
}

final class LifecycleLauncher: LauncherApplicationDelegate {
    var enabled = true
    override var isLauncherEnabled: Bool { enabled }
}

func drainScan(_ delegate: LauncherApplicationDelegate) throws {
    let deadline = Date().addingTimeInterval(5)
    while delegate.scanning && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try check(!delegate.scanning, "Background scan must finish within the test deadline")
}

func withLifecycleLauncher(_ name: String, _ body: (LifecycleLauncher, URL) throws -> Void) throws {
    let directory = sandbox.appendingPathComponent(name)
    let original = ProcessInfo.processInfo.environment["LOOMEX_FLOW_SUPPORT_DIR"]
    setenv("LOOMEX_FLOW_SUPPORT_DIR", directory.path, 1)
    defer {
        if let original { setenv("LOOMEX_FLOW_SUPPORT_DIR", original, 1) }
        else { unsetenv("LOOMEX_FLOW_SUPPORT_DIR") }
    }
    let roots = directory.appendingPathComponent("empty-apps")
    try FileManager.default.createDirectory(at: roots, withIntermediateDirectories: true)
    let delegate = LifecycleLauncher(product: .loomex, applicationRoots: [roots])
    defer { delegate.stopLauncher() }
    try body(delegate, directory.appendingPathComponent("Launch"))
}

test("module creation stays hidden and stop releases the canvas and its local monitor") {
    try withLifecycleLauncher("module-release") { delegate, _ in
        weak var canvas: LaunchCanvas?
        try autoreleasepool {
            try delegate.startLauncher()
            canvas = delegate.canvas
            let window = delegate.launcherWindow
            try delegate.startLauncher()
            try check(window === delegate.launcherWindow, "Repeated start reuses the module")
            try check(window?.isVisible == false && canvas?.resourcesSuspended == true, "Enable does not steal focus")
            delegate.enabled = false
            delegate.stopLauncher()
        }
        try drainScan(delegate)
        try check(canvas == nil && delegate.store == nil && delegate.launcherWindow == nil,
                  "Stopping releases the canvas (whose deinit removes its monitor), window and store")
    }
}

test("late scan after disable cannot modify a retained layout") {
    try withLifecycleLauncher("module-late-scan") { delegate, directory in
        let store = try LayoutStore(directory: directory)
        try store.reconcile(apps: [.app(path: "/Fixture/Preserved.app", name: "Preserved")])
        let original = try Data(contentsOf: store.fileURL)
        try delegate.startLauncher()
        delegate.enabled = false
        delegate.stopLauncher()
        try drainScan(delegate)
        let after = try Data(contentsOf: store.fileURL)
        try check(after == original, "The stale empty scan cannot remove the stored app")
    }
}

test("reenable during a scan waits then reconciles only the new module") {
    try withLifecycleLauncher("module-reenable") { delegate, directory in
        let store = try LayoutStore(directory: directory)
        try store.reconcile(apps: [.app(path: "/Fixture/Removed.app", name: "Removed")])
        try delegate.startLauncher()
        delegate.enabled = false
        delegate.stopLauncher()
        delegate.enabled = true
        try delegate.startLauncher()
        try check(delegate.scanning, "The original request retains its slot until completion")
        try drainScan(delegate)
        try check(delegate.store?.layout.apps.isEmpty == true, "A fresh scan reconciles the new module")
        try check(delegate.canvas?.resourcesSuspended == true, "Background enable retains no grid resources")
    }
}

print("RESULT: \(passed) passed, \(failed) failed")
if failed != 0 { exit(1) }
