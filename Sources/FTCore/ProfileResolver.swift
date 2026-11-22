// ProfileResolver.swift
// 実行プロファイルとアプリプロファイルの合成・検証。プロファイルのモデル全体の説明は RunProfile.swift の冒頭

import Foundation

// MARK: - 解決

public enum ProfileResolver {

    /// profiles/runs/ の実行プロファイル名一覧(拡張子なし、名前順)
    public static func runProfileNames(project: TestProject) -> [String] {
        jsonNames(in: project.runsDir)
    }

    /// 実行プロファイルの `reportDir` の解決(相対はプロジェクトルート基準・未指定は `reports`)。
    /// **resolve と保持容量の掃除の唯一の定義元** —— 別々に解くと掃除が実際の置き場を見落とす
    public static func reportDirectory(_ reportDir: String?, project: TestProject) -> URL {
        URL(fileURLWithPath: resolvePath(reportDir ?? "reports", base: project.rootURL))
    }

    /// 実行プロファイルが `reportDir` で指す置き場(解決済み・読めないプロファイルは飛ばす)。
    /// 既定の `reports/` 以外に書かれたレポートを保持容量の掃除が拾うため(`RetentionSweeper.reportSessions`)
    public static func configuredReportDirectories(project: TestProject) -> [URL] {
        runProfileNames(project: project).compactMap { name in
            let url = project.runsDir.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(RunProfileDocument.self, from: data),
                  let dir = doc.reportDir else { return nil }
            return reportDirectory(dir, project: project)
        }
    }

    /// profiles/apps/ のアプリケーションプロファイル名一覧
    public static func appProfileNames(project: TestProject) -> [String] {
        jsonNames(in: project.appsDir)
    }

    /// 実行プロファイルが使う(enabled の)デバイスを「どの機械に居るか」付きで返す(ディスパッチ判定用。
    /// フルの resolve() はアプリ解決まで行い、machine を決める前に落ちうるのでこちらを使う)。
    /// 読めなければ空(警告と中止は resolve() が受け持つ)
    /// - overrides: `--set` の上書き。**resolve() と同じものを渡す** —— `--set app=` は対象 OS を変え、
    ///   どのデバイスが走るかが変わる(渡さないとディスパッチの計画と resolve が別のデバイス集合を見る)
    public static func runDeviceMachines(project: TestProject, runProfileName: String,
                                         overrides: [String: RunProfileSetValue] = [:]) -> [RunDeviceMachine] {
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard let runData = try? Data(contentsOf: runURL),
              let loadedRunDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData) else {
            return []
        }
        let runDoc = PhysicalDeviceUse.applying(
            to: loadedRunDoc.applyingOverrides(overrides), off: PhysicalDeviceUse.isOff()).doc
        let entries = DeviceMachineGrouping.entries(runDevices: runDoc.devices ?? [], enabledOnly: true)
        return AppPlatformScoping.partition(
            entries, scope: AppPlatformScoping.scope(project: project, runDoc: runDoc)).kept
            .map { RunDeviceMachine(machine: $0.machine, name: $0.name, platform: $0.platform) }
    }

    /// `enabled: false` で実行から外れているデバイス(machine 含む)。`runDeviceMachines` に載らない理由を言うために引く。
    public static func disabledRunDevices(project: TestProject, runProfileName: String,
                                          overrides: [String: RunProfileSetValue] = [:]) -> [RunDeviceMachine] {
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard let runData = try? Data(contentsOf: runURL),
              let loadedRunDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData) else { return [] }
        let runDoc = loadedRunDoc.applyingOverrides(overrides)
        return (runDoc.devices ?? []).filter { !$0.isEnabled }.map { device in
            RunDeviceMachine(machine: MachineDispatch.normalize(device.spec.machine), name: device.spec.name,
                             platform: device.platform)
        }
    }

    /// プロファイルでは有効なのに、設定タブ「実機をテストで使用する」OFF で実行から外れている実機(PhysicalDeviceUse)。
    /// `disabledRunDevices`(JSON の `enabled: false`)と分けるのは、断りの文が案内する直し方が違うため
    public static func physicallyExcludedRunDevices(project: TestProject, runProfileName: String,
                                                    overrides: [String: RunProfileSetValue] = [:]) -> [RunDeviceMachine] {
        guard PhysicalDeviceUse.isOff() else { return [] }
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard let runData = try? Data(contentsOf: runURL),
              let loadedRunDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData) else { return [] }
        let runDoc = loadedRunDoc.applyingOverrides(overrides)
        return (runDoc.devices ?? []).filter { $0.isEnabled && $0.spec.isPhysical }.map { device in
            RunDeviceMachine(machine: MachineDispatch.normalize(device.spec.machine), name: device.spec.name,
                             platform: device.platform)
        }
    }

    /// 実行プロファイルの文書(`--set` 適用後)が計測の run か。**フルの resolve() を経由しない** —— 機械別の分割の前の台数の検査
    /// (DeviceMachineRunner.plan)が使い、選んでいない別のデバイスの設定の誤りで resolve が失敗しても判定を飛ばさないため。
    /// 読めない・デコードできないときは false(そのときは runDeviceMachines も空 = 分割の計画は作られない)
    public static func declaresResponseMeasurement(project: TestProject, runName: String,
                                                   overrides: [String: RunProfileSetValue] = [:]) -> Bool {
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard let data = try? Data(contentsOf: runURL),
              let doc = try? JSONDecoder().decode(RunProfileDocument.self, from: data) else { return false }
        return doc.applyingOverrides(overrides).responseMeasurement == true
    }

    /// 実行プロファイルのバリアント(解決済み。宣言順)。`variants` が無ければ空。**読めない・無いプロファイルは空**(別の段が断る)。
    /// 宣言の誤りと `--set` の併用は投げる。run の入口(`run` / `api run` / 機械分担 / 複数対象)がバリアントの展開に使う1箇所
    public static func declaredVariants(project: TestProject, runName: String,
                                        overrides: [String: RunProfileSetValue] = [:]) throws -> [ResolvedVariant] {
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard let data = try? Data(contentsOf: runURL),
              let loaded = try? JSONDecoder().decode(RunProfileDocument.self, from: data) else { return [] }
        return try resolveVariants(loaded: loaded, overrides: overrides, run: runName)
    }

    static func resolveVariants(loaded: RunProfileDocument, overrides: [String: RunProfileSetValue],
                                run: String) throws -> [ResolvedVariant] {
        guard let entries = loaded.variants else { return [] }
        try RunVariantResolution.rejectSetOverrides(overrides, run: run)
        return try RunVariantResolution.resolve(
            entries: entries, topAppearance: loaded.appearance, topTextSize: loaded.textSize,
            topOrientation: loaded.orientation, run: run)
    }

    /// runProfileName の実行プロファイルが宣言する `remoteControl.workspace`(trim 後非空)を返す。
    /// ファイルが無い/デコード不能/未宣言・空文字列なら nil。**マシン解決を必要としないので
    /// フルの resolve() を経由しない** —— リモートディスパッチ(Sources/fleetest/
    /// RemoteRunDispatcher.swift)はミラーの要否だけを知りたく、実行するマシンはまだ決めていない
    public static func declaredWorkspace(project: TestProject, runName: String) -> String? {
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard let data = try? Data(contentsOf: runURL),
              let doc = try? JSONDecoder().decode(RunProfileDocument.self, from: data),
              let workspace = doc.remoteControl?.workspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty else {
            return nil
        }
        return workspace
    }

    /// `resolveWorkspaceRoot` の軽量版(declaredWorkspace を読むだけ。マシン/デバイス解決を
    /// 経由しない —— RemoteRunDispatcher がミラー前に、実行するマシンを決める前に呼ぶ)。
    /// override は渡さない(このホストがワークスペースを最初に組み立てる側 = `--workspace` は
    /// 子プロセスへの中継専用で、ここでは常に無指定)
    public static func effectiveWorkspaceRoot(project: TestProject, runName: String) -> URL {
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        return resolveWorkspaceRoot(
            declared: declaredWorkspace(project: project, runName: runName), override: nil,
            projectRoot: project.rootURL, repoRoot: repoRoot)
    }

    /// 実行プロファイルが指すアプリの、その OS のアプリ ID を軽量に読む(デバイスを解決しない)。読めなければ nil
    public static func declaredAppID(project: TestProject, runName: String, platform: String) -> String? {
        guard let runData = try? Data(contentsOf: project.runsDir.appendingPathComponent("\(runName).json")),
              let appRef = (try? JSONDecoder().decode(RunProfileDocument.self, from: runData))?.app,
              let appData = try? Data(contentsOf: project.appsDir.appendingPathComponent("\(appRef).json")),
              let appProfile = try? JSONDecoder().decode(AppProfile.self, from: appData) else { return nil }
        return appProfile.section(for: platform).app
    }

    /// ステージング対象(appPath の原本)だけを軽量に読む。マシン/デバイス解決を経由しない
    /// (declaredWorkspace と同じ理由 —— RemoteRunDispatcher はミラー直前にここだけ要る)。
    /// 戻り値: platform("ios"/"android") → (原本の絶対パス, 生の宣言文字列)
    /// (appPath 未指定の platform は含まない)。プロファイル/アプリ定義が読めなければ空を返す
    /// - overrides: `--set` の上書き。**向こうの子へ中継するものと同じものを渡す**(既定値を置かない)——
    ///   `--set app=` は向こうの resolve が別のアプリを選ぶので、渡さないと元のアプリの原本を運び、
    ///   向こうは前の run が置いた古い原本で黙って走るか、原本が無くて落ちる
    public static func declaredAppPaths(project: TestProject, runName: String,
                                        overrides: [String: RunProfileSetValue]) -> [DeclaredAppPath: DeclaredAppPathEntry] {
        guard let runData = try? Data(
                contentsOf: project.runsDir.appendingPathComponent("\(runName).json")),
              let loadedRunDoc = try? JSONDecoder().decode(RunProfileDocument.self, from: runData),
              let appRef = loadedRunDoc.applyingOverrides(overrides).app else { return [:] }
        guard let appData = try? Data(
                contentsOf: project.appsDir.appendingPathComponent("\(appRef).json")),
              let appProfile = try? JSONDecoder().decode(AppProfile.self, from: appData) else { return [:] }
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        var result: [DeclaredAppPath: DeclaredAppPathEntry] = [:]
        for platform in ["ios", "android"] {
            let section = appProfile.section(for: platform)
            if let raw = section.appPath {
                result[DeclaredAppPath(platform: platform, physical: false)] =
                    DeclaredAppPathEntry(source: resolvePath(raw, base: repoRoot), declared: raw)
            }
            // **この経路はデバイスを解決しない**(devices を読まない軽量読み)ので
            // 「そのランナーに実機が居るか」を知らない。居る場合に運び忘れると向こうで
            // 仮想デバイス用ビルドを実機へ入れて 0xe8008014 で落ちるため、宣言があれば運ぶ
            if let raw = section.appPathPhysical {
                result[DeclaredAppPath(platform: platform, physical: true)] =
                    DeclaredAppPathEntry(source: resolvePath(raw, base: repoRoot), declared: raw)
            }
        }
        return result
    }

    /// `remoteControl.workspace` 宣言と `--workspace` 上書きから実効の生値(未解決)を決める。
    /// override が非空なら常に勝つ(中継されたリモートの子はこれで自分のリポジトリルート基準を
    /// 上書きする)。両方無ければ nil(未宣言 = リポジトリルート基準)。
    /// 純粋関数として切り出す(デバイス・ファイル I/O 不要のためテストが直接叩ける)
    public static func effectiveWorkspaceRaw(declared: String?, override: String?) -> String? {
        func trimmedNonEmpty(_ s: String?) -> String? {
            guard let s else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return trimmedNonEmpty(override) ?? trimmedNonEmpty(declared)
    }

    /// `remoteControl.workspace` の実効ルート(絶対パス解決済み)。優先順は
    /// **override(`--workspace`) > declared(`remoteControl.workspace`) > 既定**。
    /// **既定は `"<projectRoot>/workspace"`**(常に非 nil を返す ——
    /// ワークスペースは常に有効。declared/override 省略時に repoRoot 基準へ戻すと、
    /// 呼び出し側ごとに「省略時どう扱うか」の分岐が要る)。declared/override が相対パスなら
    /// repoRoot 基準で解決する(絶対パスならそのまま)。純粋関数(I/O なし)
    public static func resolveWorkspaceRoot(
        declared: String?, override: String?, projectRoot: URL, repoRoot: URL
    ) -> URL {
        guard let raw = effectiveWorkspaceRaw(declared: declared, override: override) else {
            return projectRoot.appendingPathComponent(WorkspaceScaffold.defaultRootName)
        }
        return URL(fileURLWithPath: resolvePath(raw, base: repoRoot))
    }

    /// 実行プロファイルを合成して ResolvedProfile を返す。
    /// - workspaceOverride: `--workspace`(hidden)。実行プロファイルの `remoteControl.workspace` を
    ///   上書きする。リモートディスパッチが、ミラー先を実行するマシンの子へ伝えるのに使う
    ///   (RemoteRunDispatcher が必ず渡す。渡さないと子は自分のリポジトリルート基準で appPath を
    ///   解決し、リモートに転送されていない絶対パスを見に行く)
    public static func resolve(project: TestProject, runName: String,
                               workspaceOverride: String? = nil,
                               overrides: [String: RunProfileSetValue] = [:]) throws -> ResolvedProfile {
        var warnings: [String] = []

        // 1. 実行プロファイル
        let runURL = project.runsDir.appendingPathComponent("\(runName).json")
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            throw ProfileError.runProfileNotFound(
                name: runName, available: runProfileNames(project: project))
        }
        let loadedRunDoc: RunProfileDocument = try load(runURL, warnings: &warnings) { json in
            checkKeys(json, allowed: RunProfileDocument.knownKeys, context: "runs/\(runName).json")
                + checkDeviceEntryKeys(json, context: "runs/\(runName).json")
                + checkRemoteControlKeys(json, context: "runs/\(runName).json")
        }
        // `--set` はここで一度だけ当てる(読み込み直後・解決より前)。以降の全処理はこの
        // runDoc だけを見るので、全キーが個別の配線無しで効く(RunProfileDocument.applyingOverrides)
        let runDoc = loadedRunDoc.applyingOverrides(overrides)
        let variants = try resolveVariants(loaded: loadedRunDoc, overrides: overrides, run: runName)
        guard let appRef = runDoc.app else {
            throw ProfileError.missingAppReference(run: runName)
        }
        guard let deviceRefs = runDoc.devices, !deviceRefs.isEmpty else {
            throw ProfileError.missingDevices(run: runName)
        }

        // 2. アプリケーションプロファイル
        let appURL = project.appsDir.appendingPathComponent("\(appRef).json")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw ProfileError.appProfileNotFound(
                name: appRef, available: appProfileNames(project: project))
        }
        let appProfile: AppProfile = try load(appURL, warnings: &warnings) { json in
            checkAppProfileKeys(json, context: "apps/\(appRef).json")
        }

        // 3. デバイス(enabled のデバイスだけ)。一意なのは (machine, name)。別マシンの同名は許す
        // (DeviceMachineGrouping にすべての規則がある)。重複は無効のデバイスも含めて見る(台帳として壊れている)
        if let duplicate = DeviceMachineGrouping.firstDuplicate(
            in: DeviceMachineGrouping.entries(runDevices: deviceRefs, enabledOnly: false)) {
            throw ProfileError.duplicateDeviceName(
                name: duplicate.name, deviceMachine: duplicate.machine, run: runName)
        }
        // 設定タブ「実機をテストで使用する」が OFF なら実機を enabled: false として読む(PhysicalDeviceUse)
        let physical = PhysicalDeviceUse.applying(
            to: runDoc, off: PhysicalDeviceUse.isOff())
        let allEnabledEntries = DeviceMachineGrouping.entries(runDevices: physical.doc.devices ?? [], enabledOnly: true)
        guard !allEnabledEntries.isEmpty else {
            if !physical.excluded.isEmpty {
                throw ProfileError.physicalDevicesNotUsed(run: runName, devices: physical.excluded)
            }
            throw ProfileError.noEnabledDevices(run: runName)
        }
        if !physical.excluded.isEmpty {
            warnings.append(PhysicalDeviceUse.excludedWarning(physical.excluded, run: runName))
        }
        // アプリプロファイルの platform が対象外にした OS のデバイスは無視(JSON は変えない)
        let appScope = appProfile.platform ?? .hybrid
        let scoped = AppPlatformScoping.partition(allEnabledEntries, scope: appScope)
        for entry in scoped.ignored {
            warnings.append(AppPlatformScoping.ignoredWarning(entry: entry, app: appRef, scope: appScope))
        }
        let enabledEntries = scoped.kept
        guard !enabledEntries.isEmpty else {
            throw ProfileError.noDevicesForAppPlatform(
                run: runName, app: appRef, scope: appScope, ignored: scoped.ignored.count)
        }

        if runDoc.responseMeasurement == true {
            // デバイスの台数・種類は `--device` / `--runner local` で絞った後に入口で検査する(ResponseMeasurementPolicy の冒頭)
            try ResponseMeasurementPolicy.validateSettings(runDoc, run: runName)
        } else {
            try ResponseMeasurementPolicy.validateRepeatScope(runDoc, run: runName)
        }

        // 4. iOS のモード: 実行プロファイルの iosMode(既定 inapp-boost。レスポンス計測の run は xcuitest = 計測は XCUITest ランナーにしか無い)。
        // デバイスに mode を明示していればそちらが優先(上書きしない)
        if let value = runDoc.iosMode, !IOSMode.all.contains(value) {
            throw ProfileError.invalidIOSMode(run: runName, device: nil, value: value)
        }
        let iosMode = runDoc.iosMode ?? (runDoc.responseMeasurement == true ? IOSMode.xcuitest : IOSMode.inappBoost)
        var devices: [ResolvedDevice] = []
        for entry in enabledEntries {
            // 実体の無い登録は走る前に言う(iOS は既定名へ落ちて別のデバイスで黙って走る)。
            // 止めはしない —— 既定に頼っている既存プロファイルを赤にしない
            if entry.spec.lacksConcreteTarget {
                warnings.append(
                    "device \"\(entry.name)\" on machine \(DeviceMachineGrouping.display(entry.machine))"
                    + " has no concrete target (ios: udid/osVersion, android: avd/serial)"
                    + " — re-run `fleetest profile setup --auto-device`,"
                    + " or fill it in in profiles/runs/\(runName).json")
            }
            let device = ResolvedDevice(platform: entry.platform, spec: entry.spec)
            try validatePhysical(device, run: runName)
            if let value = device.spec.mode, !IOSMode.all.contains(value) {
                throw ProfileError.invalidIOSMode(run: runName, device: entry.name, value: value)
            }
            // 実機 iOS も同じ解決(明示 > iosMode の既定)。
            // 実機の inapp-boost モードは、アプリが開発署名でなければ供給が xcuitest モードへ黙って縮退する(BridgeProvisioner)
            if device.platform == "ios", device.spec.mode == nil {
                var spec = device.spec
                spec.mode = iosMode
                devices.append(ResolvedDevice(platform: "ios", spec: spec))
            } else {
                // プロファイルの iosMode を明示したのにデバイス側の mode が勝つ組み合わせは
                // GUI の選択が「効かない」ように見えるため警告で知らせる
                if device.platform == "ios", runDoc.iosMode != nil,
                   let explicit = device.spec.mode {
                    warnings.append(
                        "device \"\(entry.name)\" explicitly sets mode=\(explicit), "
                        + "so the iosMode setting does not apply to it")
                }
                devices.append(device)
            }
        }

        // 5. アプリ解決(デバイスのある platform ごと。)
        // appPath の相対パスは常に「リポジトリルート」基準(project.rootURL =
        // <repoRoot>/TestProjects/<name> の2階層上。= アプリの原本の場所)。**ワークスペースの
        // 有無・既定/明示のどれでもこの基準は変えない**(ワークスペース基準へ切り替えない ——
        // 原本の置き場所とインストールに使う場所は別物。RR-17)。packageRoot() の CWD 走査は使わない(単体テストでは CWD が
        // 本体リポジトリを指し誤基準になる。project.rootURL からの決定的導出で統一)。
        // reportDir だけはプロジェクト直下に出すため下記で project.rootURL 基準のまま
        // (基準が異なるので resolvePath の base で使い分ける)。
        //
        // **ワークスペースは常に有効**(既定 `"<project.rootURL>/workspace"`)。
        // インストールに使うパス(ResolvedAppTarget.appPath)は常に
        // "<workspaceRoot>/apps/<原本のファイル名>" に切り替わる(原本の
        // ResolvedAppTarget.sourcePath は常にリポジトリルート基準のまま)。実体のコピー(ステージング)
        // はここでは行わない(純粋な path 計算のみ) —— 呼び出し側(ProfileRunner.run/ApiRunCommand/
        // RemoteRunDispatcher/MCP の resolveProfileTarget)が resolve() 直後に `WorkspaceAppStaging` を呼んで原本を運ぶ。
        // リモートへディスパッチすると appPath のアプリパッケージ自体は転送されない
        // (RemoteTransferPlan.rsyncArgs は TestProjects/<project> しか rsync しない)ため、
        // リポジトリルート基準の絶対パスはリモートに存在しない。既定のワークスペースは
        // project.rootURL 配下なので、その転送(rsyncArgs)自体がステージング済みの apps/ を
        // 運ぶ ―― 明示指定でプロジェクト外を指したときだけ専用ミラーが要る
        // (`WorkspaceRemoteDispatch.placement`。Sources/fleetest/RemoteRunDispatcher.swift)
        let repoRoot = project.rootURL.deletingLastPathComponent().deletingLastPathComponent()
        let workspaceRoot = resolveWorkspaceRoot(
            declared: runDoc.remoteControl?.workspace, override: workspaceOverride,
            projectRoot: project.rootURL, repoRoot: repoRoot)
        // 開始/終了スクリプト。パス計算だけで、ファイルの有無は見ない —— それは実行側
        // (RunHookRunner)が action() で判定する(resolve は I/O を増やさない)
        let setupHook = RunHookPlan.resolve(kind: .setup, workspaceRoot: workspaceRoot)
        let teardownHook = RunHookPlan.resolve(kind: .teardown, workspaceRoot: workspaceRoot)
        var apps: [String: ResolvedAppTarget] = [:]
        for platform in Set(devices.map(\.platform)) {
            let section = appProfile.section(for: platform)
            guard let bundleID = section.app else {
                throw ProfileError.missingBundleID(platform: platform, appProfile: appRef)
            }
            let sourcePath = section.appPath.map { resolvePath($0, base: repoRoot) }
            // installPath の名前空間は section.appPath(生の宣言文字列)から作る —— resolvePath 後の
            // 絶対パス(sourcePath)は repoRoot 込みでホストごとに違うため、そこから作ると
            // ローカルとリモートの子で違うステージ先になってしまう(WorkspaceAppStaging.installPath の doc)
            let installPath = section.appPath.map { declared in
                WorkspaceAppStaging.installPath(declared: declared, workspaceRoot: workspaceRoot)
            }
            let physicalSource = section.appPathPhysical.map { resolvePath($0, base: repoRoot) }
            for (key, declared, path) in [("appPath", section.appPath, sourcePath),
                                          ("appPathPhysical", section.appPathPhysical, physicalSource)] {
                if let declared, let path, AppPathLocation.isAbsoluteDeclaration(declared), AppPathLocation.isTemporary(path) {
                    warnings.append(AppPathLocation.temporaryWarning(
                        appProfile: appRef, platform: platform, key: key, path: path))
                }
            }
            let physicalInstallPath = section.appPathPhysical.map { declared in
                WorkspaceAppStaging.installPath(declared: declared, workspaceRoot: workspaceRoot,
                                                physical: true)
            }
            apps[platform] = ResolvedAppTarget(
                bundleID: bundleID,
                appName: section.appName,
                sourcePath: sourcePath,
                appPath: installPath,
                sourcePathPhysical: physicalSource,
                appPathPhysical: physicalInstallPath,
                // **appPath があれば既定で有効**。パスを書いたのに入らない(既定 false)方が
                // 事故で、警告を出さないと気付けない設計だった。止めたいときだけ
                // autoInstall: false を明示する(opt-out)。実インストールは中身が変わったときだけ
                autoInstall: appProfile.autoInstall
                    ?? (section.appPath != nil || section.appPathPhysical != nil),
                healthCheckURL: appProfile.healthCheckURL)
            // **iOS の実機にシミュレータ用ビルドは入らない**(未署名 = 0xe8008014)。
            // インストールの失敗は run の途中(ブリッジ供給の後)に出るので、
            // ここで先に言う。止めはしない。**appPath 自体が実機用ビルドなら鳴らさない**
            // (Info.plist の CFBundleSupportedPlatforms で判る)。**原本(sourcePath)が読めなければ
            // ステージ済みの複製(installPath)を読む** —— リモートの子は原本を持たず
            // ステージ先の複製だけを持つため、sourcePath だけを見ると常に nil(判らない)になり
            // 実機用ビルドが appPath に入っている場合でも誤って警告が鳴る。両方読めないときだけ
            // 鳴らす(安全側)
            if platform == "ios", section.appPathPhysical == nil, section.appPath != nil,
               (AppBundleInspector.declaresDevicePlatform(appPath: sourcePath)
                   ?? AppBundleInspector.declaresDevicePlatform(appPath: installPath)) != true,
               devices.contains(where: { $0.platform == "ios" && $0.spec.isPhysical }) {
                warnings.append(
                    "the run includes a physical iOS device but apps/\(appRef).json has no"
                    + " \"appPathPhysical\" — a simulator build cannot be installed on a device"
                    + " (it is unsigned); set appPathPhysical to a device build")
            }
            // appName はアイコン名を兼ねる(AppBundleInspector.appNameMismatchWarning の doc)。
            // 読めるのは iOS の .app と Android の .apk(aapt / aapt2 が SDK に無ければ黙る。.apks・.aab は読まない)。
            // 候補は原本2つの和 —— 片方にしか無い名前でも一致すれば黙る(誤検知を出さない側)
            if platform == "ios" || platform == "android", let appName = section.appName {
                var candidates: [String] = []
                for path in [sourcePath, physicalSource].compactMap({ $0 }) {
                    let names = platform == "ios"
                        ? AppBundleInspector.iconNameCandidates(appPath: path)
                        : AndroidAppLabelInspector.labelCandidates(apkPath: path)
                    for name in names
                    where !candidates.contains(name) {
                        candidates.append(name)
                    }
                }
                if let warning = AppBundleInspector.appNameMismatchWarning(
                    appRef: appRef, platform: platform, appName: appName, candidates: candidates) {
                    warnings.append(warning)
                }
            }
        }

        if let raw = runDoc.reportDir, RunProfileDocument.isBlankReportDir(raw) {
            throw ProfileError.emptyReportDir(run: runName)
        }
        let reportDir = reportDirectory(runDoc.reportDir, project: project)

        let wipeDataThresholdGB = runDoc.wipeDataThresholdGB ?? 8
        guard wipeDataThresholdGB > 0 else {
            throw ProfileError.invalidWipeDataThreshold(run: runName)
        }

        let locale = (runDoc.locale ?? "ja_JP").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidLocale(locale) else {
            throw ProfileError.invalidLocale(run: runName)
        }
        if let raw = runDoc.orientation, FTOrientation.parse(raw) == nil {
            throw ProfileError.invalidOrientation(run: runName, value: raw)
        }
        if let raw = runDoc.appearance, FTAppearance.parse(raw) == nil {
            throw ProfileError.invalidAppearance(run: runName, value: raw)
        }
        if let raw = runDoc.textSize, FTTextSize.parse(raw) == nil {
            throw ProfileError.invalidTextSize(run: runName, value: raw)
        }

        // デバイスに依存しない実効設定(FM の子トグルからの合成含む)は `--profile` 無しの直接実行
        // (`fleetest run`/`fleetest api run` の profile-less パス)と1つの関数を共有する
        // (DeviceIndependentRunSettings.resolve)。ここでしか決まらないデバイス依存の欄
        // (iosMode 等。RunProfileDocument.profileOnlyKeys)だけ runDoc から直接読む
        let settings = DeviceIndependentRunSettings.resolve(runDoc)

        return ResolvedProfile(
            project: project,
            runName: runName,
            appName: appProfile.resolvedAppName ?? appRef,
            apps: apps,
            devices: devices,
            fm: settings.fm,
            heal: settings.heal,
            reportDir: reportDir,
            defaultTimeout: runDoc.defaultTimeout,
            scenarioTimeout: runDoc.scenarioTimeout,
            wipeDataOnBloat: runDoc.wipeDataOnBloat ?? true,
            updateWebView: runDoc.updateWebView ?? true,
            wipeDataThresholdGB: wipeDataThresholdGB,
            recoverCpuFallbackToGpu: runDoc.recoverCpuFallbackToGpu ?? false,
            locale: locale,
            iosPreActionPing: settings.iosPreActionPing,
            containerInference: settings.containerInference,
            ocrTextVisibilityCheck: settings.ocrTextVisibilityCheck,
            preferCheckStateClassifier: settings.preferCheckStateClassifier,
            enableAnimations: settings.enableAnimations,
            responseMeasurement: settings.responseMeasurement,
            responseRepeat: settings.responseRepeat,
            homeOnStart: settings.homeOnStart,
            playProtectBypass: settings.playProtectBypass,
            record: settings.record,
            recordFailuresOnly: settings.recordFailuresOnly,
            recordBitrateKbps: RunProfileDocument.effectiveRecordBitrateKbps(runDoc.recordBitrateKbps),
            recordFullResolution: settings.recordFullResolution,
            workspaceRoot: workspaceRoot,
            setupHook: setupHook,
            teardownHook: teardownHook,
            warnings: warnings,
            reportDirDeclared: runDoc.reportDir != nil,
            orientation: settings.orientation,
            appearance: settings.appearance, textSize: settings.textSize,
            variants: variants)
    }

    /// 実機デバイスの整合検査。enabled のデバイスにのみ適用する
    /// (無効のデバイスの不備で run を止めない)
    private static func validatePhysical(_ device: ResolvedDevice, run: String) throws {
        guard device.spec.isPhysical else { return }
        let identifier = device.platform == "ios" ? device.spec.udid : device.spec.serial
        guard let identifier, !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProfileError.physicalDeviceMissingIdentifier(
                name: device.name, platform: device.platform, run: run)
        }
        // 実機の inapp-boost モードは、アプリが開発署名でなければ供給が xcuitest モードへ黙って縮退する(ユーザー決定)。
        // ここでは mode を拒否しない —— 縮退は供給時に注入可否を実機のアプリから判定する(BridgeProvisioner)
    }

    /// locale 形式検証(trim 済み文字列を渡すこと): 言語[-地域/バリアント...](BCP47 風の緩い検査)
    private static func isValidLocale(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
    }

    /// チルダ展開+相対パスは呼び出し側が渡す base 基準で絶対化
    /// (base は用途で異なる: appPath=リポジトリルート / reportDir=プロジェクトルート。resolve 参照)
    public static func resolvePath(_ path: String, base: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// デコード失敗を「どのキーが・何を期待したか」で言う(型の違いだけではどの欄を直すか分からない)
    static func describeDecodingError(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            var out = ""
            for key in context.codingPath {
                if let index = key.intValue { out += "[\(index)]" }
                else { out += (out.isEmpty ? "" : ".") + key.stringValue }
            }
            return out.isEmpty ? "the top level" : "\"" + out + "\""
        }
        switch error as? DecodingError {
        case .typeMismatch(let type, let context)?:
            return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context)?:
            return "\(path(context)): expected \(type), got null"
        case .keyNotFound(let key, let context)?:
            let parent = context.codingPath.isEmpty ? "" : " in " + path(context)
            return "missing \"\(key.stringValue)\"\(parent)"
        case .dataCorrupted(let context)?:
            return "\(path(context)): \(context.debugDescription)"
        default:
            return "type mismatch"
        }
    }

    // MARK: - 単一ファイル検証(プロファイルエディタ用)

    /// プロファイルファイル 1 つの検証。戻り値: (エラー, 警告)。
    /// エラー = デコード不能・必須欠落・name 重複、警告 = 未知キー(タイポ検出)
    public static func validate(
        kind: ProfileFileKind, data: Data, context: String
    ) -> (errors: [String], warnings: [String]) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return (["cannot parse as JSON (syntax error)"], [])
        }
        guard let json = parsed as? [String: Any] else {
            let got = parsed is [Any] ? "an array" : "a single value"
            return (["the top level must be a JSON object ({ ... }), not \(got)"], [])
        }
        var errors: [String] = []
        var warnings: [String] = []
        let decoder = JSONDecoder()
        switch kind {
        case .app:
            do { _ = try decoder.decode(AppProfile.self, from: data) } catch {
                errors.append("cannot load as an app profile (\(describeDecodingError(error)))")
            }
            warnings += checkAppProfileKeys(json, context: context)
        case .run:
            if let doc = try? decoder.decode(RunProfileDocument.self, from: data) {
                if doc.app == nil { errors.append("no \"app\" (a reference into apps/)") }
                let devices = doc.devices ?? []
                if devices.isEmpty { errors.append("no \"devices\"") }
                // **一意なのは (machine, name)**(別の機械の同名は重複ではない)。判定は
                // DeviceMachineGrouping で resolve() と共有する —— 片方だけ厳しいと
                // 「保存できるのに検証が赤い」(その逆も)になる
                if let duplicate = DeviceMachineGrouping.firstDuplicate(
                    in: DeviceMachineGrouping.entries(runDevices: devices, enabledOnly: false)) {
                    errors.append("duplicate device name: \(duplicate.name)"
                                  + " on machine \(DeviceMachineGrouping.display(duplicate.machine))"
                                  + " (\(duplicateDeviceNameRule))")
                }
                for entry in devices where entry.isEnabled {
                    errors += physicalDeviceErrors(entry.spec, platform: entry.platform)
                }
                if let threshold = doc.wipeDataThresholdGB, threshold <= 0 {
                    errors.append("\"wipeDataThresholdGB\" must be a positive number (GB)")
                }
                if let raw = doc.reportDir, RunProfileDocument.isBlankReportDir(raw) {
                    errors.append("\"reportDir\" must not be empty (omit it to use reports/)")
                }
                if let kbps = doc.recordBitrateKbps, !(1...RunProfileDocument.maxRecordBitrateKbps).contains(kbps) {
                    warnings.append("\"recordBitrateKbps\" is \(kbps); a value of 0 or less, or above \(RunProfileDocument.maxRecordBitrateKbps), is ignored"
                        + " and the default (\(VideoRecordingConfig.defaultBitrateKbps) kbps) is used")
                }
                // 負値・0・NaN はホストの watchdog(ScenarioHost.watchdogDuration)まで
                // 届くと壊れた/意味の無い挙動になる(0 秒 watchdog・即トリガー)
                if let scenarioTimeout = doc.scenarioTimeout, scenarioTimeout < 1 {
                    errors.append("\"scenarioTimeout\" must be a positive number of seconds")
                }
                // 検証待ち(defaultTimeout)の 0 は正当(初回スナップショットだけを見る)。負値だけ断る
                if let defaultTimeout = doc.defaultTimeout, !(defaultTimeout >= 0 && defaultTimeout.isFinite) {
                    errors.append("\"defaultTimeout\" must be a non-negative, finite number of seconds (0 = the first snapshot only, no waiting)")
                }
                let locale = (doc.locale ?? "ja_JP").trimmingCharacters(in: .whitespacesAndNewlines)
                if !isValidLocale(locale) {
                    errors.append("\"locale\" must look like ja_JP")
                }
                if let raw = doc.orientation, FTOrientation.parse(raw) == nil {
                    errors.append("\"orientation\" \(RunProfileDocument.orientationRule)")
                }
                if let raw = doc.appearance, FTAppearance.parse(raw) == nil {
                    errors.append("\"appearance\" \(FTAppearance.rule)")
                }
                if let raw = doc.textSize, FTTextSize.parse(raw) == nil {
                    errors.append("\"textSize\" \(FTTextSize.rule)")
                }
                if let entries = doc.variants {
                    errors += RunVariantResolution.problems(entries: entries, topOrientation: doc.orientation)
                        .map { "\"variants\": \($0)" }
                }
            } else {
                let reason: String
                do { _ = try decoder.decode(RunProfileDocument.self, from: data); reason = "" }
                catch { reason = describeDecodingError(error) }
                errors.append("cannot load as a run profile (\(reason))")
            }
            warnings += checkKeys(json, allowed: RunProfileDocument.knownKeys, context: context)
            warnings += checkDeviceEntryKeys(json, context: context)
            warnings += checkRemoteControlKeys(json, context: context)
        }
        return (errors, warnings)
    }

    // MARK: - 内部ヘルパー

    /// エディタ用の実機検査(resolve 側の validatePhysical と同じ規則を文言だけ単体ファイル向けにしたもの)
    private static func physicalDeviceErrors(_ spec: DeviceSpec, platform: String) -> [String] {
        guard spec.isPhysical else { return [] }
        var errors: [String] = []
        let field = platform == "ios" ? "udid" : "serial"
        let identifier = platform == "ios" ? spec.udid : spec.serial
        if (identifier?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty {
            errors.append("device \"\(spec.name)\" is kind=physical but has no \"\(field)\"")
        }
        // 実機の inapp-boost モードはエディタでは許す(開発署名でなければ供給が xcuitest モードへ縮退する。BridgeProvisioner)
        return errors
    }

    private static func jsonNames(in dir: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// デコード+未知キー検査(タイポ検出)。未知キーは警告のみでエラーにしない
    private static func load<T: Decodable>(
        _ url: URL, warnings: inout [String],
        keyCheck: ([String: Any]) -> [String]
    ) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProfileError.decodeFailed(url, detail: error.localizedDescription)
        }
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProfileError.decodeFailed(url, detail: "\(error)")
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            warnings.append(contentsOf: keyCheck(json))
        }
        return value
    }

    private static func checkKeys(_ json: [String: Any], allowed: Set<String>,
                                  context: String) -> [String] {
        json.keys.filter { !allowed.contains($0) }.sorted().map {
            "\(context): unknown key \"\($0)\" is ignored"
        }
    }

    private static func checkDeviceEntryKeys(_ json: [String: Any], context: String) -> [String] {
        guard let devices = json["devices"] as? [[String: Any]] else { return [] }
        return devices.flatMap {
            checkKeys($0, allowed: RunDeviceEntry.knownKeys, context: "\(context) devices")
        }
    }

    private static func checkRemoteControlKeys(_ json: [String: Any], context: String) -> [String] {
        guard let section = json["remoteControl"] as? [String: Any] else { return [] }
        return checkKeys(section, allowed: RemoteControlSection.knownKeys, context: "\(context) remoteControl")
    }

    private static func checkAppProfileKeys(_ json: [String: Any], context: String) -> [String] {
        var warnings = checkKeys(json, allowed: AppProfile.knownKeys, context: context)
        for key in AppProfile.sectionKeys {
            guard let section = json[key] as? [String: Any] else { continue }
            warnings += checkKeys(section, allowed: AppProfileSection.knownKeys, context: "\(context) \(key)")
        }
        return warnings
    }
}
