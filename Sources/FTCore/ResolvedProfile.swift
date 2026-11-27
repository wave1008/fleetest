// ResolvedProfile.swift
// 実行プロファイルの解決済みモデル。プロファイルのモデル全体の説明は RunProfile.swift の冒頭

import Foundation

// MARK: - 解決済みモデル

/// 実行プロファイルから解決されたデバイス(所属プラットフォーム確定)
public struct ResolvedDevice: Sendable, Hashable {
    public let platform: String  // "ios" / "android"
    public let spec: DeviceSpec
    public var name: String { spec.name }

    public init(platform: String, spec: DeviceSpec) {
        self.platform = platform
        self.spec = spec
    }
}

/// プラットフォーム毎に解決されたアプリ情報
/// `declaredAppPaths` の鍵。ワークスペースへ運ぶ対象は platform だけでは決まらない
/// (実機用ビルドは別ファイル・別のステージング先)
public struct DeclaredAppPath: Hashable, Sendable {
    public let platform: String
    public let physical: Bool
    public init(platform: String, physical: Bool) {
        self.platform = platform
        self.physical = physical
    }
}

/// `declaredAppPaths` の値。`source` はステージング(実コピー)の入力、`declared` は
/// `WorkspaceAppStaging.installPath` の名前空間の入力 —— 別々に持つのは、`source` が
/// repoRoot 込みの絶対パス(ホストごとに違う)なのに対し、`declared` はプロファイル JSON の
/// 生の文字列(ローカル・リモートの子で常に同じ)だから。installPath は必ず `declared` を使う
public struct DeclaredAppPathEntry: Sendable, Equatable {
    public let source: String
    public let declared: String
    public init(source: String, declared: String) {
        self.source = source
        self.declared = declared
    }
}

public struct ResolvedAppTarget: Sendable, Hashable {
    public let bundleID: String
    /// アプリの原本の絶対パス(常にリポジトリルート基準で解決済み。nil = appPath 未指定。
    /// ワークスペースの宣言有無・既定/明示のどれでも基準は変わらない)。`WorkspaceAppStaging`
    /// がここを読んでワークスペースへコピーする。「原本が見つからない」系のエラーはこちらを
    /// 名指しする(インストール先を出しても何をビルドすればよいか分からないため)
    public let sourcePath: String?
    /// インストールに実際に使う絶対パス(nil = インストールしない)。**ワークスペースは常に
    /// 有効**(既定 `<project.rootURL>/workspace`)なので sourcePath と同値になるのは
    /// appPath 自体が既にワークスペース配下を指している場合だけ。`WorkspaceAppStaging.installPath`
    /// が決める "<workspaceRoot>/apps/<原本のファイル名>"(ProfileResolver.resolve が唯一の生成元)。
    /// 呼び出し側(installApp・ProfileWorkerFactory 等)はこちらだけを見ればよい
    public let appPath: String?
    /// 実機向けパッケージの原本(nil = appPathPhysical 未指定 = 実機にも appPath を配る)
    public let sourcePathPhysical: String?
    /// 実機向けパッケージのインストールに使う絶対パス(ステージング先。nil = 未指定)
    public let appPathPhysical: String?
    /// 実行前に appPath を自動インストールするか(既定 false = 無効。
    /// アプリプロファイルの最上位 autoInstall)
    public let autoInstall: Bool
    /// バックエンド死活確認 URL(AppProfile.healthCheckURL)
    public let healthCheckURL: String?
    /// その OS のアイコン名(`<platform>.appName`)。tapAppIcon() の引数省略時の既定として子へ渡す。
    /// **OS ごとに持つ** —— 同じアプリでもランチャの表示名は OS で違う(E2E-Flutter は iOS
    /// `Ft E2e Flutter` / Android `ft_e2e_flutter`)。run で1つに畳むと片方の OS で別名を探して落ちる
    public let appName: String?

    /// **配るパッケージは端末の種別で決まる**(この規則の唯一の定義元)。実機に
    /// `appPathPhysical` が無ければ appPath に落ちる —— iOS ではまず入らない(シミュレータ用
    /// ビルドは署名が無い)が、Android は同じ APK が両方で動くので落とすのが正しい。
    /// 「実機なのに実機用が無い」を install の失敗より手前で言うのは ProfileValidation の役目
    public func packagePath(physical: Bool) -> String? {
        physical ? (appPathPhysical ?? appPath) : appPath
    }

    /// sourcePath 省略時は appPath と同値にする(ワークスペース非経由の既存呼び出しとの互換)
    /// `appName` に既定値を置かない(新しい生成元の渡し忘れをコンパイルで止める)
    public init(bundleID: String, appName: String?, sourcePath: String? = nil, appPath: String? = nil,
                sourcePathPhysical: String? = nil, appPathPhysical: String? = nil,
                autoInstall: Bool = false, healthCheckURL: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.sourcePath = sourcePath ?? appPath
        self.appPath = appPath
        self.sourcePathPhysical = sourcePathPhysical ?? appPathPhysical
        self.appPathPhysical = appPathPhysical
        self.autoInstall = autoInstall
        self.healthCheckURL = healthCheckURL
    }
}

/// 合成・検証済みの実行プロファイル。実行コードはこれだけを見る
public struct ResolvedProfile: Sendable {
    public let project: TestProject
    public let runName: String
    /// ログの見出しに出すアプリ名(apps/<name>.json の appName。無ければファイル名)。**OS を問わず1つ**なので
    /// tapAppIcon の既定には使わない(そちらは `apps[platform].appName`)
    public let appName: String
    /// platform("ios"/"android")→ アプリ情報(デバイスがある platform のみ)
    public let apps: [String: ResolvedAppTarget]
    /// 実行に使うデバイス。**limitingDevices が本数に合わせて絞る**ので var
    public var devices: [ResolvedDevice]
    /// FM 機能の実効設定(RunProfileDocument の fmTextVisibilityCheck/screenLooksLike を合成)
    public let fm: FMConfig
    /// ロケータ自己修復(指紋照合)を許可するか。**`fm` の配下ではない**
    public let heal: Bool
    /// 絶対パス解決済み
    public let reportDir: URL
    public let defaultTimeout: Double?
    /// シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。nil=未指定→run 側で既定 90 を適用)
    public let scenarioTimeout: Int?
    /// 実行開始時に Android AVD 肥大化を Wipe Data するか(既定 true)
    public let wipeDataOnBloat: Bool
    /// **テスト開始時に WebView を揃えるか**(既定 true)
    /// (`AndroidWebViewUpdate`。adb に更新コマンドは無いので、接続中で最も新しい端末から配る)
    public let updateWebView: Bool
    /// wipeDataOnBloat のしきい値(GB)
    public let wipeDataThresholdGB: Double
    /// 実行開始時に CPU 描画フォールバック機を GPU で起動し直すか
    /// (RunProfileDocument.recoverCpuFallbackToGpu。既定 false)
    public let recoverCpuFallbackToGpu: Bool
    /// Android エミュレータのブート後にブリッジ /locale で適用するロケール(既定 "ja_JP")
    public let locale: String
    /// interop WebView の直前の接続確認(RunProfileDocument.iosPreActionPing。**既定 true**)
    public let iosPreActionPing: Bool
    /// 容器の推測に依存する補正(RunProfileDocument.containerInference。**既定 true**)
    public let containerInference: Bool
    /// OCR を使ったテキストの可視性検証の実効値(RunProfileDocument.ocrTextVisibilityCheck。既定 true)
    public let ocrTextVisibilityCheck: Bool
    /// RunProfileDocument.preferCheckStateClassifier の実効値(既定 true)
    public let preferCheckStateClassifier: Bool
    /// アプリのアニメーションを残すか(RunProfileDocument.enableAnimations。既定 false=無効化)
    public let enableAnimations: Bool
    /// レスポンス計測モード(RunProfileDocument.responseMeasurement。既定 false)
    public let responseMeasurement: Bool
    /// 計測モードで各シナリオを続けて回す回数(RunProfileDocument.responseRepeat)
    public let responseRepeat: Int
    /// run 開始時に各デバイスへ home() を撃つか(RunProfileDocument.homeOnStart。**既定 true**)
    public let homeOnStart: Bool
    /// Play Protect の照会をバイパスするか(RunProfileDocument.playProtectBypass。**既定 true**)
    public let playProtectBypass: Bool
    /// 各ワーカーを run 全体で録画し、シナリオごとに切り出すか(RunProfileDocument.record。**既定 true**。profile-less は false)
    public let record: Bool
    /// 成功したシナリオのクリップを保存しないか(RunProfileDocument.recordFailuresOnly。既定 false)
    public let recordFailuresOnly: Bool
    /// クリップ再エンコードの目標 bitrate(kbps。RunProfileDocument.recordBitrateKbps。既定 1000)
    public let recordBitrateKbps: Int
    /// 半分解像度化をスキップするか(RunProfileDocument.recordFullResolution。既定 false)
    public let recordFullResolution: Bool
    /// **絶対パス解決済みのワークスペースルート**(remoteControl.workspace / `--workspace` 上書きの
    /// 実効値)。**常に非 nil**(既定 `<project.rootURL>/workspace` —— ワークスペースは
    /// 常に有効。`ProfileResolver.resolveWorkspaceRoot`)。appPath の原本の解決基準はこれの
    /// 有無に関わらず常にリポジトリルート ―― `apps[platform].appPath`(インストール先)だけが
    /// この配下の `apps/<ファイル名>` に切り替わる(ステージングは WorkspaceAppStaging)。
    /// リモートディスパッチはこれがプロジェクトルート配下かどうかで転送経路を分ける
    /// (`WorkspaceRemoteDispatch.placement`。配下ならプロジェクト転送がそのまま運ぶので専用
    /// ミラーは不要。Sources/fleetest/RemoteRunDispatcher.swift)。**`var` にする**(machine と
    /// 同じ理由 —— 既定値付きの `let` は memberwise init から除外され、この引数を知らない
    /// 既存テストの直接呼び出しが壊れる。型を Optional のまま残すのも同じ理由 ——
    /// 非 Optional にすると同じ既存テストが nil を渡せなくなる)
    public var workspaceRoot: URL? = nil
    /// run の前後で走らせる利用者のスクリプト(`<workspace>/scripts/run-setup.sh`・`run-teardown.sh`)。
    /// **workspaceRoot と同じく既定値付きの `var`**(memberwise init を直に呼ぶ既存テストのため)。
    /// 実行するかどうかは**ファイルがあるかどうか**だけで決まる(`RunHookPlan.action`)
    public var setupHook: RunHook? = nil
    public var teardownHook: RunHook? = nil
    /// 解決中に出た警告(スキップしたデバイス・未知キー等)。呼び出し側が表示する
    public let warnings: [String]
    /// プロファイル(か `--set reportDir=`)が `reportDir` を書いたか。`reportDir` は未指定でも既定のパスを持つので、
    /// 「書いた」はパスの一致ではなくこの印で見る(既定と同じ `reports` を明記したプロファイルも書いた側。dry-run の置き場の判断)。
    /// **既定値付きの `var`**(memberwise init を直に呼ぶ既存テストのため)
    public var reportDirDeclared = false
    /// RunProfileDocument.orientation(既定 nil = 向きに触らない)。**既定値付きの `var`**(memberwise init を直に呼ぶ既存テストのため)
    public var orientation: FTOrientation? = nil
    /// RunProfileDocument.appearance / textSize(既定 nil = 指定なし)。**既定値付きの `var`**(memberwise init を直に呼ぶ既存テストのため)
    public var appearance: FTAppearance? = nil
    public var textSize: FTTextSize? = nil
    /// 解決済みのバリアント(宣言順。空 = バリアントの無い run)。各値は「指定あり」(RunVariantResolution)。既定値付きの `var`(memberwise init を直に呼ぶ既存テストのため)
    public var variants: [ResolvedVariant] = []

    public var iosDevices: [ResolvedDevice] { devices.filter { $0.platform == "ios" } }
    /// platform を宣言していないシナリオをどちらの OS で走らせるか(iOS のデバイスがあれば ios)。**唯一の規則** ——
    /// 実行(`run` / `api run` の既定 platform)・dry-run の列挙・台数の見積り(`scenarioCounts`)が全部ここを通す。
    /// 別々に持つと、同じ `--profile android-run --dry-run` が CLI だけ iOS を検証して緑になり、
    /// 見積りが両 OS に数えて走らない側の OS の台を用意していた
    public var undeclaredScenarioPlatform: String { iosDevices.isEmpty ? "android" : "ios" }

    /// 台数の見積りに使う OS ごとの本数(platform 未宣言は `undeclaredScenarioPlatform` の側にだけ数える)。
    /// 一覧が確定しているときに使う = 0 は「その OS で走るシナリオが無い」(`limitingDevices` はその OS の台を用意しない)
    public func scenarioCounts(platforms: [String?]) -> (ios: Int, android: Int) {
        let resolvedPlatforms = platforms.map { $0 ?? undeclaredScenarioPlatform }
        return (resolvedPlatforms.filter { $0 == "ios" }.count, resolvedPlatforms.filter { $0 == "android" }.count)
    }
    public var androidDevices: [ResolvedDevice] { devices.filter { $0.platform == "android" } }

    /// **回す本数を超える台数を用意しない**。1本のシナリオを回すのに 10 台ぶんのブリッジ供給と
    /// アプリ版チェックを払うのは丸損で、実測では iOS の固定費 14.8s のほとんどがこれだった
    /// (合計 21.8s のうちテスト実行は 7.0s)。
    ///
    /// **予備は置かない**(本数ぶんだけ)。欠けた台のぶんは残りの台が消化する(供給は部分失敗を許容)。止まるのは
    /// その OS の台が1台も残らないときだけ。予備を起こして待つと全台の合流が遅れ、待たずに後から合流させると
    /// 起動の負荷がテストに重なる → MN-103。
    /// 用意する台数。**判断はここだけ**(テストはこの純粋関数を直接叩く)。
    /// `scenarios == nil` は「本数が分からない」(一覧の前に台数を決める経路で、ID が `Class.method` だけでない)= 絞らない。
    /// **0 は「分からない」ではない** —— 一覧が確定していて、その OS で走るシナリオが無い = 1台も用意しない
    /// (0 を絞らないと読むと、Android だけの run が混在プロファイルの iOS を全台用意していた)
    public static func deviceKeepCount(available: Int, scenarios: Int?) -> Int {
        guard let scenarios else { return available }
        return min(available, scenarios)
    }

    /// `run --device` の絞り込み(マシン別サブ実行が「自分のぶんのデバイス」だけを回すのに使う)。
    /// 空配列は「絞らない」。**1台も残らない指定は呼び出し側でエラーにする** ——
    /// ここで黙って全台に戻すと、名前を打ち間違えたときに意図しないデバイスで走る
    /// マシン別サブ実行のスコープ。**一意なのは name 単体ではなく (host, name)** なので、
    /// 名前だけで絞ると**別の機械の同名デバイスまで掴む**(フリートの各機は同じ命名規則で
    /// シミュレータを作るので、同名は例外ではなく通常。実走で確認 ——
    /// 手元のサブ実行が3機ぶんの "iPhone …-01" を全部拾って8台になった)。
    /// - deviceMachine: そのサブ実行が担当する機械("local" / 登録名。nil = ホストで絞らない)
    public func filteringDevices(names: [String], deviceMachine: String? = nil) -> ResolvedProfile {
        guard !names.isEmpty || deviceMachine != nil else { return self }
        let wanted = Set(names)
        let wantedHost = MachineDispatch.normalize(deviceMachine)
        var filtered = self
        filtered.devices = devices.filter { device in
            if !wanted.isEmpty, !wanted.contains(device.name) { return false }
            guard deviceMachine != nil else { return true }
            return MachineDispatch.normalize(device.spec.machine) == wantedHost
        }
        return filtered
    }

    /// `avoiding` のデバイス(MCP が操作しているデバイス。ユーザー決定「避けて、足りなければ警告して使う」)は、**ほかのデバイスで
    /// 本数ぶん足りるなら外す**。本数が分からない(nil = 絞らない)ときは、ほかにデバイスがあれば外す。足りないときだけ足りない
    /// ぶんを加える。本数 0 はその OS の台を外す(`deviceKeepCount`)。**既定値を置かない** —— 呼び出し元が渡し忘れると黙って
    /// MCP のデバイスを使う形へ戻る
    ///
    /// **台の条件(DR-237)**: `requirements` に空でない組があれば、条件の組ごとに合う台を1台先に残し(`DeviceRequirementTrim.mustKeep`。
    /// 観測 `traits` は台の名前で引く)、本数の残りを従来の順で埋める。**宣言が無い run(空配列)は従来の `prefix` と同一**。
    /// 必須の台が MCP の操作中でも残す(呼び手が警告する)。本数 0 の OS には必須の台も残さない
    public func limitingDevices(iosScenarios: Int?, androidScenarios: Int?,
                                requirements: [DeviceRequirementSet], traits: [String: DeviceTraits],
                                avoiding: (ResolvedDevice) -> Bool) -> ResolvedProfile {
        func keep(_ list: [ResolvedDevice], _ count: Int?) -> [ResolvedDevice] {
            let free = list.filter { !avoiding($0) }
            let avoided = list.filter(avoiding)
            let must = count == 0 ? [] : DeviceRequirementTrim.mustKeep(
                devices: list, requirements: requirements, traits: traits)
            guard !must.isEmpty else {
                guard let count else { return free.isEmpty ? avoided : free }
                if free.count >= count {
                    return Array(free.prefix(Self.deviceKeepCount(available: free.count, scenarios: count)))
                }
                let total = Self.deviceKeepCount(available: list.count, scenarios: count)
                return free + avoided.prefix(total - free.count)
            }
            guard let count else {
                let base = free.isEmpty ? avoided : free
                return list.filter { must.contains($0) || base.contains($0) }
            }
            var kept = list.filter { must.contains($0) }
            let total = Self.deviceKeepCount(available: list.count, scenarios: count)
            for device in free + avoided where !must.contains(device) {
                if kept.count >= total { break }
                kept.append(device)
            }
            return kept
        }
        let kept = Set(keep(iosDevices, iosScenarios) + keep(androidDevices, androidScenarios))
        guard kept.count < devices.count else { return self }
        var trimmed = self
        trimmed.devices = devices.filter { kept.contains($0) }
        return trimmed
    }
}

/// プロファイルファイルの種別(profiles/ 配下のサブディレクトリと対応)
public enum ProfileFileKind: String, CaseIterable, Sendable {
    case app, run

    /// profiles/ 配下のサブディレクトリ名
    public var directoryName: String {
        switch self {
        case .app: return "apps"
        case .run: return "runs"
        }
    }

    public var label: String {
        switch self {
        case .app: return "app"
        case .run: return "run"
        }
    }
}
