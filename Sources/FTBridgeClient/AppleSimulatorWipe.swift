import Foundation
import FTCore

/// Simulator 上の Apple のアプリ(`com.apple.*`)のデータ消去。**MCP の ft_clear_app_data だけが呼ぶ**
/// (DSL の clearAppData は `BridgeClient.clearAppDataOnSimulator` のまま = 子プロセスが撃つ simctl は増えない。
/// ここが撃つ `get_app_container … groups` は SandboxBroker の許可形に無い = 子から呼ぶと断られる。
/// `AppleSimulatorWipeScopeTests` が呼び手を固定)。
/// データコンテナに加えて **App Group コンテナ**も空にする(Apple のアプリは設定・状態を group.com.apple.* に置く)
public enum AppleSimulatorWipe {
    public struct GroupContainer: Equatable, Sendable {
        public let id: String
        public let path: String
    }

    public struct Report: Equatable, Sendable {
        public var dataContainerPath: String
        public var dataItemsRemoved: Int
        public var groups: [(id: String, path: String, itemsRemoved: Int)] = []
        /// 事実だけ(撃てなかった・消せなかったもの)。空でなければ「全部消えた」と言わない
        public var problems: [String] = []

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.dataContainerPath == rhs.dataContainerPath && lhs.dataItemsRemoved == rhs.dataItemsRemoved
                && lhs.problems == rhs.problems && lhs.groups.count == rhs.groups.count
                && zip(lhs.groups, rhs.groups).allSatisfy { $0.id == $1.id && $0.path == $1.path && $0.itemsRemoved == $1.itemsRemoved }
        }
    }

    /// containermanagerd が容器の識別に使う印。group の容器では消さない(消すと容器が孤児になりうる)
    static let containerMetadataName = ".com.apple.mobile_container_manager.metadata.plist"

    /// `simctl get_app_container <udid> <bundle> groups` の出力(1行 = `<id><空白><絶対パス>`)。
    /// 読めない行は捨てて数だけ返す(空行は数えない)。id は空白を含まない・パスは空白を含みうる
    static func parseGroupContainers(_ output: String) -> (groups: [GroupContainer], unparsableLines: Int) {
        var groups: [GroupContainer] = []
        var unparsable = 0
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let split = line.firstIndex(where: { $0 == "\t" || $0 == " " }) else { unparsable += 1; continue }
            let id = String(line[..<split])
            let path = line[split...].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains("/"), path.hasPrefix("/") else { unparsable += 1; continue }
            groups.append(GroupContainer(id: id, path: path))
        }
        return (groups, unparsable)
    }

    /// ディレクトリの**中身**を消す(ディレクトリ自体は残す)。戻り = (消した数, 消せなかった名前)。
    /// 根が symlink なら辿らず nil(子が差し替えうる場所 = clearAppDataOnSimulator と同じ規律)
    static func emptyContents(of path: String, skipping: Set<String> = []) -> (removed: Int, failed: [String])? {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { return nil }
        var removed = 0
        var failed: [String] = []
        for entry in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !skipping.contains(entry) {
            do { try fm.removeItem(atPath: path + "/" + entry); removed += 1 } catch { failed.append(entry) }
        }
        return (removed, failed)
    }

    /// 応答の本文(事実だけ)
    public static func summary(bundleID: String, report: Report) -> String {
        var lines = ["Wiped \(report.dataItemsRemoved) item(s) from the data container of \(bundleID) (\(report.dataContainerPath))."]
        if report.groups.isEmpty {
            lines.append("App group containers: none wiped.")
        } else {
            lines.append("App group containers wiped: \(report.groups.count) — "
                + report.groups.map { "\($0.id) (\($0.itemsRemoved) item(s))" }.joined(separator: ", ") + ".")
        }
        for problem in report.problems { lines.append("NOT done: \(problem)") }
        // 消したのは容器2種だけ。連絡先は端末全体のストアに残る(Simulator の Library/AddressBook。他のアプリも読むので消さない)
        lines.append("NOT touched: device-wide stores outside these containers (for example the contacts in the simulator's"
            + " Library/AddressBook, which every app shares), so data the app keeps there remains.")
        return lines.joined(separator: "\n")
    }

    /// 止める → データコンテナ → 各 group コンテナを空にし、設定のキャッシュを落とし(`SimulatorPreferencesFlush`)、権限を戻す。
    /// データコンテナの失敗は投げる(消えたと言えない)。group の列挙・消去・権限の失敗は `problems` に事実で残す
    public static func wipe(bundleID: String, udid: String) throws -> Report {
        try BridgeClient.stopOnSimulator(
            bundleID: bundleID, target: udid,
            purpose: "before clearing its data (clearing under a running app lets it write its state back)")
        let data = try Shell.run(["xcrun", "simctl", "get_app_container", udid, bundleID, "data"],
                                 timeout: InstalledAppCheck.containerQueryTimeoutSeconds)
        guard let dataOutput = data.outputIfSucceeded else {
            throw DriverError.badResponse(status: Int(data.status),
                body: "simctl get_app_container failed (is \(bundleID) installed?): \(data.tail)")
        }
        let dataPath = dataOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dataPath.hasPrefix("/") else {
            throw DriverError.badResponse(status: 500, body: "could not resolve the data container for \(bundleID)")
        }
        // 設定のキャッシュは空にする前に cfprefsd に消させる(group の分は下で同じく。理由と順序は SimulatorPreferencesFlush 冒頭)
        // symlink の容器は辿らない(下の emptyContents が断る。その前に先の設定を消させない)
        func flushUnlessLinked(_ container: String) -> [(path: String, detail: String)] {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: container)) != nil ? []
                : SimulatorPreferencesFlush.flush(udid: udid, domainPaths: SimulatorPreferencesFlush.domainPaths(container: container))
        }
        var unflushed = flushUnlessLinked(dataPath)
        guard let dataWipe = emptyContents(of: dataPath) else {
            throw DriverError.badResponse(status: 500,
                body: "the data container of \(bundleID) is a symbolic link (\(dataPath)) — refusing to delete what it points to")
        }
        guard dataWipe.failed.isEmpty else {
            throw DriverError.badResponse(status: 500,
                body: "could not delete \(dataWipe.failed.count) item(s) in the data container of \(bundleID):"
                    + " \(dataWipe.failed.prefix(5).joined(separator: ", "))")
        }
        var report = Report(dataContainerPath: dataPath, dataItemsRemoved: dataWipe.removed)

        let listing = try Shell.run(["xcrun", "simctl", "get_app_container", udid, bundleID, "groups"],
                                    timeout: InstalledAppCheck.containerQueryTimeoutSeconds)
        if let listed = listing.outputIfSucceeded {
            let parsed = parseGroupContainers(listed)
            if parsed.unparsableLines > 0 {
                report.problems.append("\(parsed.unparsableLines) line(s) of the group container listing could not be read, so any group container on them was not wiped")
            }
            for group in parsed.groups {
                unflushed += flushUnlessLinked(group.path)
                guard let result = emptyContents(of: group.path, skipping: [containerMetadataName]) else {
                    report.problems.append("group container \(group.id) (\(group.path)) is a symbolic link — not wiped")
                    continue
                }
                if result.failed.isEmpty {
                    report.groups.append((group.id, group.path, result.removed))
                } else {
                    report.problems.append("could not delete \(result.failed.count) item(s) in group container \(group.id):"
                        + " \(result.failed.prefix(5).joined(separator: ", "))")
                }
            }
        } else {
            report.problems.append("could not list the app group containers (simctl get_app_container … groups exited"
                + " \(listing.status): \(listing.tail)) — none were wiped")
        }

        for failure in unflushed {
            report.problems.append("could not clear the cached preferences \((failure.path as NSString).lastPathComponent)"
                + " (\(failure.detail)) — preference values cached by the daemon may come back")
        }
        let privacy = try Shell.run(["xcrun", "simctl", "privacy", udid, "reset", "all", bundleID])
        if privacy.status != 0 {
            report.problems.append("simctl privacy reset failed (exit \(privacy.status): \(privacy.tail)) — permission grants remain")
        }
        return report
    }
}
