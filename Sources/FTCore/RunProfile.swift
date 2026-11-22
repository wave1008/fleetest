// RunProfile.swift
// 実行プロファイルの組み合わせ型モデル。
//   apps/<name>.json     … アプリケーションプロファイル(最上位 platform/autoInstall/healthCheckURL + ios/android セクション)
//   runs/<name>.json     … 実行プロファイル(app 参照+デバイスの実体リスト+実行時設定)
// ProfileResolver が 2 つを合成して ResolvedProfile(検証済み)を作る。
// 実行コード(CLI/MCP)は ResolvedProfile のみを参照する。
// **デバイスの台帳は実行プロファイルの devices だけ**(同じデバイスが複数の実行プロファイルに載る。
// 編集・削除は同じ (platform, machine, name) を持つ全ファイルへ伝播する = RunProfileDeviceEditor)。
// JSON 形式は vscode-fleetest/schemas/{app,run}-profile.schema.json と同期を要する
// (knownKeys・必須/任意フィールドを変更したらスキーマ側も更新する)。

import Foundation

// MARK: - JSON ドキュメント(ファイルの素の形)

/// アプリケーションプロファイルの ios/android セクション
public struct AppProfileSection: Codable, Sendable, Equatable {
    /// ユーザーがアプリを識別するための表示名(レポート/ログで使用)
    public var appName: String?
    /// bundle identifier / パッケージ名
    public var app: String?
    /// パッケージファイル(.app / .apk / .apks)のパス。プロジェクトルート相対 or 絶対 or ~
    public var appPath: String?
    /// **実機に配るパッケージ**のパス(省略時は appPath)。iOS はシミュレータ用ビルド
    /// (iphonesimulator SDK・未署名)を実機へ入れられない —— `0xe8008014 invalid signature` で
    /// インストールが失敗するため、同じアプリでも成果物が2つ要る。**端末ごとにアプリ
    /// プロファイルを分けない**ためのフィールド(ユーザー決定)。
    /// Android は同じ APK が両方で動くので普通は書かない
    public var appPathPhysical: String?

    public init(appName: String? = nil, app: String? = nil,
                appPath: String? = nil, appPathPhysical: String? = nil) {
        self.appName = appName
        self.app = app
        self.appPath = appPath
        self.appPathPhysical = appPathPhysical
    }

    /// ios/android セクションが読むキー。読まないキーを既知に入れると checkAppProfileKeys の
    /// 未知キー警告をすり抜け、書いたのに効かない設定が黙る
    static let knownKeys: Set<String> = ["appName", "app", "appPath", "appPathPhysical"]
}

/// アプリプロファイルの対象 OS。キー無しは hybrid と同じ扱い(両 OS)
public enum AppPlatformScope: String, Codable, Sendable, Equatable, CaseIterable {
    case ios, android, hybrid

    public func includes(platform: String) -> Bool {
        self == .hybrid || self.rawValue == platform
    }
}

/// アプリプロファイル。最上位キーは platform / autoInstall / healthCheckURL / ios / android
/// (**この並びが書き出し順の契約**: OrderedProfileJSON)。autoInstall・healthCheckURL は OS 横断の運用設定
public struct AppProfile: Codable, Sendable, Equatable {
    /// 対象 OS(省略 = hybrid = 両方)。対象外 OS のデバイスは実行時に無視される(AppPlatformScoping)
    public var platform: AppPlatformScope?
    /// 実行前に appPath を自動インストールするか(未指定なら appPath の有無で決まる。false 明示で opt-out)
    public var autoInstall: Bool?
    /// アプリが依存するバックエンドの死活確認 URL。実行開始前に到達確認し、不達なら警告する
    /// (バックエンド停止でアプリがクラッシュ→全滅する事故の早期検知)。ブロックはしない
    public var healthCheckURL: String?
    public var ios: AppProfileSection?
    public var android: AppProfileSection?

    public init(platform: AppPlatformScope? = nil, autoInstall: Bool? = nil,
                healthCheckURL: String? = nil,
                ios: AppProfileSection? = nil, android: AppProfileSection? = nil) {
        self.platform = platform
        self.autoInstall = autoInstall
        self.healthCheckURL = healthCheckURL
        self.ios = ios
        self.android = android
    }

    static let knownKeys: Set<String> = ["platform", "autoInstall", "healthCheckURL", "ios", "android"]
    /// セクション(中身を検査する)キー
    static let sectionKeys: [String] = ["ios", "android"]

    /// platform に対応するセクション(無ければ空)
    public func section(for platform: String) -> AppProfileSection {
        switch platform {
        case "ios": return ios ?? AppProfileSection()
        case "android": return android ?? AppProfileSection()
        default: return AppProfileSection()
        }
    }

    /// ログの見出し用の表示名(ios/android セクションのみ)。
    /// **OS を畳んだ値なので tapAppIcon の既定に使わない**(OS ごとの名前は `section(for:).appName`)
    public var resolvedAppName: String? {
        ios?.appName ?? android?.appName
    }
}

/// デバイスの実体種別。省略時は virtual(既存プロファイルは無改修で動く)
public enum DeviceKind: String, Codable, Sendable, Hashable {
    /// iOS シミュレータ / Android エミュレータ
    case virtual
    /// 実機(iOS は udid、Android は serial で同定する)
    case physical
}

/// デバイス 1 台の実体定義(実行プロファイルの devices[] 1要素から platform/enabled を除いたもの)
public struct DeviceSpec: Codable, Sendable, Hashable {
    /// デバイスの名前。**iOS シミュレータではシミュレータ自身の名前**(Xcode の Name = simctl の名前)と
    /// 一致させる —— udid が無いときはこの名前(+ os)でシミュレータを探す。拡張の編集フォームでは
    /// iOS シミュレータの名前を変えさせない(変えるとシミュレータ側とずれる)。
    /// **一意なのは name 単体ではなく (machine, name)** —— 別のホストに同名のデバイスが居てよい
    /// (フリートの各機が同じ命名規則でシミュレータを作るため、同名は例外ではなく通常)
    public var name: String
    /// このデバイスが居る機械。省略時は手元(ツールは常に明示して書く)。
    /// 書けるのは**登録名**だけ(ssh の実体は書けない = プロファイルはプロジェクト資産)。
    /// 解決規則は DeviceMachineGrouping、正規化は MachineDispatch.normalize。
    /// **JSON キーは "machine"**。旧キー "host" は読まない(knownKeys に無い = 未知キーの警告)
    public var machine: String?
    /// 実体種別(省略時 virtual)。実機の識別子は iOS=udid / Android=serial
    public var kind: DeviceKind?
    /// OS バージョン(Xcode の OS Version と同じ表記。例 "iOS 27.0" / Android 実機は "Android 13")。
    /// **JSON キーは "osVersion"**。iOS シミュレータでは udid が無いときの実体解決に使う
    /// (省略時は名前一致の最新)。実機では**表示専用**(model と同じく登録時に控えるだけ)
    public var osVersion: String?
    /// iOS: UDID。kind=virtual ならシミュレータ UDID(name/os より優先)、
    /// kind=physical なら実機の識別子(必須)。`xcrun devicectl list devices` の Identifier 列と
    /// ハードウェア UDID("00008130-..." 形式)のどちらでも解決する(内部では常に後者に正規化。
    /// xcodebuild の -destination id= が受け付けるのは後者だけのため)
    public var udid: String?
    /// iOS: ブリッジポートの固定(省略時は自動採番)
    public var port: UInt16?
    /// iOS: モード("inapp-boost" / "xcuitest" = `IOSMode`)。省略時は実行プロファイルの iosMode
    public var mode: String?
    /// Android: AVD(ID または表示名。起動中エミュレータとの照合で adb シリアルに解決)
    public var avd: String?
    /// Android 実機: adb シリアル(USB は "14141JEC204922"、WiFi は "192.168.1.23:5555")。
    /// kind=physical のとき必須。エミュレータには使わない(avd から解決するため)
    public var serial: String?
    /// 機種名(iOS シミュレータは Xcode の Model = device type 名、iOS 実機は marketingName、
    /// Android は AVD の機種 / ro.product.model)。**表示専用**で同定には使わない
    /// (登録時に控えるだけ。端末を挿し替えても値は追随しない)
    public var model: String?

    public init(name: String, machine: String? = nil, kind: DeviceKind? = nil,
                osVersion: String? = nil,
                udid: String? = nil, port: UInt16? = nil, mode: String? = nil,
                avd: String? = nil, serial: String? = nil, model: String? = nil) {
        self.name = name
        self.machine = machine
        self.kind = kind
        self.osVersion = osVersion
        self.udid = udid
        self.port = port
        self.mode = mode
        self.avd = avd
        self.serial = serial
        self.model = model
    }

    /// 実機か(kind 省略時は virtual)。デバイス種別の分岐はすべてこれを見ること
    public var isPhysical: Bool { kind == .physical }

    /// 「どのデバイスか」が名前以外に1つも書かれていない登録。iOS は name だけで探しに行くが、
    /// 雛形の論理名(simulator1 等)は実在しないので起動時に落ちる。
    /// 見るキーは ProfileWriter.deviceBodyKeys と同集合(ProfileWriterTests が照合)
    public var lacksConcreteTarget: Bool {
        osVersion == nil && udid == nil && avd == nil && serial == nil
    }

    static let knownKeys: Set<String> = [
        "name", "machine", "kind", "osVersion", "udid", "port", "mode", "avd",
        "serial", "model",
    ]

    private enum CodingKeys: String, CodingKey {
        case name, machine, kind, osVersion, udid, port, mode, avd, serial, model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        machine = try container.decodeIfPresent(String.self, forKey: .machine)
        kind = try container.decodeIfPresent(DeviceKind.self, forKey: .kind)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        avd = try container.decodeIfPresent(String.self, forKey: .avd)
        serial = try container.decodeIfPresent(String.self, forKey: .serial)
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(machine, forKey: .machine)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encodeIfPresent(udid, forKey: .udid)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(avd, forKey: .avd)
        try container.encodeIfPresent(serial, forKey: .serial)
        try container.encodeIfPresent(model, forKey: .model)
    }
}

public struct DeviceRosterList: Codable, Sendable, Equatable {
    public var devices: [DeviceSpec]?

    public init(devices: [DeviceSpec]? = nil) { self.devices = devices }
}

/// プラットフォーム別のデバイス一覧(**メモリ上の台帳。ファイルではない**)。
/// 実行プロファイルの devices から作る(`DeviceRoster(entries:)`)。spec.machine は実効値
/// (手元 = nil)を焼き込んだものを渡すこと(DeviceMachineGrouping.entries が前提にする)
public struct DeviceRoster: Codable, Sendable, Equatable {
    public var ios: DeviceRosterList?
    public var android: DeviceRosterList?

    public init(ios: DeviceRosterList? = nil, android: DeviceRosterList? = nil) {
        self.ios = ios
        self.android = android
    }

    /// 並びは入力順を platform ごとに保つ(ios → android)
    public init(entries: [DeviceMachineGrouping.CatalogEntry]) {
        let ios = entries.filter { $0.platform == "ios" }.map(\.spec)
        let android = entries.filter { $0.platform == "android" }.map(\.spec)
        self.init(ios: ios.isEmpty ? nil : DeviceRosterList(devices: ios),
                  android: android.isEmpty ? nil : DeviceRosterList(devices: android))
    }

    public var isEmpty: Bool {
        (ios?.devices ?? []).isEmpty && (android?.devices ?? []).isEmpty
    }
}

/// `--runner`(CLI 明示)からディスパッチ先を決める純粋関数。プロファイル側には機械の既定を
/// 持たない(デバイスごとの machine はマシン別サブ実行 = DeviceMachineGrouping で配る)。
/// 呼び出し側(Sources/fleetest/RemoteCommands.swift)はここが返す名前を登録簿引きするだけ。
public enum MachineDispatch {
    public struct Decision: Equatable {
        /// 実際のディスパッチ先(nil = ローカル実行)。**マシン名(エイリアス)か、`--runner` で
        /// 直接書かれたホスト名 / IP のどちらか** —— 呼び出し側が登録簿で解決する
        public let target: String?

        public init(target: String? = nil) {
            self.target = target
        }
    }

    /// nil・空文字・trim 後 "local" は「ローカル」(nil に正規化)。devices[].machine と
    /// --runner にもこの規則を適用する
    public static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != "local" else { return nil }
        return trimmed
    }

    /// **明示 `--runner local` は「ここで走らせる」の指定**(normalize が nil に畳むのと同じ結果)
    public static func resolve(explicitTarget: String?) -> Decision {
        if isExplicitLocal(explicitTarget) { return Decision(target: nil) }
        return Decision(target: normalize(explicitTarget))
    }

    /// 生の(trim 前の)値が文字どおり "local" か。normalize 後の nil(= 未指定)とは区別する。
    /// `--runner local` と devices[].machine の "local" の両方が「ここで走らせる」の明示指定で、
    /// 判定を写すと片方だけズレるのでここが唯一の定義元
    public static func isExplicitLocal(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "local"
    }
}

/// 実行プロファイルの devices[] 1要素。JSON は**平ら**
/// (`{"platform", "machine", "name", "enabled"?, <DeviceSpec の実体キー>}`)。
/// 拡張の書き手は vscode-fleetest/src/monitorProfileForms.ts(キー集合を揃える)
public struct RunDeviceEntry: Codable, Sendable, Equatable {
    /// "ios" / "android"
    public var platform: String
    /// false = 一覧(拡張のチェックボックス)には残すが実行対象にしない。省略・true = 対象。
    /// **false のデバイスも台帳には載る**(プロファイルを選んでいないときの監視・起動の対象)
    public var enabled: Bool?
    public var spec: DeviceSpec

    public init(platform: String, spec: DeviceSpec, enabled: Bool? = nil) {
        self.platform = platform
        self.spec = spec
        self.enabled = enabled
    }

    public var isEnabled: Bool { enabled != false }

    public static let supportedPlatforms: Set<String> = ["ios", "android"]

    static let knownKeys: Set<String> = DeviceSpec.knownKeys.union(["platform", "enabled"])

    private enum CodingKeys: String, CodingKey { case platform, enabled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(String.self, forKey: .platform)
        guard Self.supportedPlatforms.contains(platform) else {
            throw DecodingError.dataCorruptedError(
                forKey: .platform, in: container,
                debugDescription: "platform must be \"ios\" or \"android\" (got \"\(platform)\")")
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        spec = try DeviceSpec(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try spec.encode(to: encoder)
    }
}

/// FM 機能の実行時トグル(実行プロファイル由来の実効値)。プロファイル経路の `enabled` は
/// `fmTextVisibilityCheck || screenLooksLike` から導く(`DeviceIndependentRunSettings.resolve`)
public struct FMConfig: Sendable, Equatable {
    /// FM を使用するか(false = 実行バイナリへ --no-fm。MCP・dry-run は明示的に false を渡す)
    public var enabled: Bool
    /// テキストの可視性検証(occlusion guard)= 誤った緑(木では一致したが実際には見えていない)の検査。
    /// **実行プロファイルの既定は true**(ユーザー決定)
    public var fmTextVisibilityCheck: Bool
    public var screenLooksLike: Bool

    /// **この既定値は実行プロファイルの既定とは別物**。プロファイル由来の値は
    /// `ResolvedProfile.fm`(RunProfileDocument の `fmTextVisibilityCheck ?? true` 等)が組み立てる。
    /// ここの既定は「プロファイルを通らない呼び出し」(MCP のシナリオ実行・dry-run 等)向けで、
    /// **FM を積極的に使わない側**に倒してある
    public init(enabled: Bool = true,
                fmTextVisibilityCheck: Bool = false, screenLooksLike: Bool = true) {
        self.enabled = enabled
        self.fmTextVisibilityCheck = fmTextVisibilityCheck
        self.screenLooksLike = screenLooksLike
    }
}

/// リモート実行の制御(RR-17)。ワークスペース(アプリのパッケージと
/// 資材を揃える共有ディレクトリ。中身の規約 apps/scripts/data は WorkspaceScaffold)の宣言。
/// run 前後のスクリプトはここでは宣言しない —— ワークスペースの `scripts/run-setup.sh` /
/// `scripts/run-teardown.sh` があれば実行される(`RunHookPlan`)。
/// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と拡張のプロファイルフォーム
public struct RemoteControlSection: Codable, Sendable, Equatable {
    /// ワークスペースのルート。絶対パス、または**リポジトリルート基準**の相対パス。
    /// appPath の解決基準には使わない(常にリポジトリルート基準のまま)——
    /// 実行時に appPath の原本をここ配下の `apps/<ファイル名>` へコピー(ステージング)し、
    /// インストールにはそちらを使う(`WorkspaceAppStaging`。RR-17)。
    /// **省略時の既定は `<project.rootURL>/workspace`**(ワークスペースは常に有効
    /// —— ここを省略しても appPath はリポジトリルート基準のままではなく、既定ワークスペースの
    /// `apps/` へ切り替わる)。優先順位・既定値の算出は `ProfileResolver.resolveWorkspaceRoot`。
    /// `--workspace` で1回限り上書き可
    public var workspace: String?

    public init(workspace: String? = nil) {
        self.workspace = workspace
    }

    static let knownKeys: Set<String> = ["workspace"]
}

/// 実行プロファイル(profiles/runs/<name>.json)
public struct RunProfileDocument: Codable, Sendable, Equatable {
    /// apps/<app>.json への参照
    public var app: String?
    /// デバイスの実体(iOS/Android 混在可 = 両OS同時実行)。enabled=false のデバイスは走らせない
    public var devices: [RunDeviceEntry]?
    /// ロケータ自己修復(指紋照合)を許可するか(既定 true)。FM は使わない
    public var heal: Bool?
    /// FM を使ったテキストの可視性検証(occlusion guard の FM の段。**既定 true**。ユーザー決定)
    /// = 誤った緑(木では一致したが実際には見えていない)の検査。OCR の段(`ocrTextVisibilityCheck`)と独立で、
    /// guard はどちらかが true なら走る(FTRuntime が合成)
    public var fmTextVisibilityCheck: Bool?
    /// screenLooksLike(screenMatches)を有効にするか(既定 true。無効時は該当ステップを skip)
    public var screenLooksLike: Bool?
    /// OCR を使ったテキストの可視性検証(occlusion guard の OCR の段。既定 true)。`fmTextVisibilityCheck` と独立で、
    /// 両方 true なら OCR が丸ごと読めた回は FM を省き、それ以外は FM と突き合わせる。こちらだけ true なら OCR だけで判定
    public var ocrTextVisibilityCheck: Bool?
    /// チェック状態(checkIsON / checkIsOFF)の判定で CheckStateClassifier を優先するか(**既定 true**)。
    /// 分類器が使えるのは `vision/classifiers/CheckStateClassifier/<ラベル>/` に画像があるときだけ。
    /// false なら a11y が状態を報告しない要素にだけ使う(VisionClassifier.swift)
    public var preferCheckStateClassifier: Bool?
    /// レポート出力先(プロジェクトルート相対 or 絶対。既定 "reports")
    public var reportDir: String?
    /// DSL コマンドの既定タイムアウト秒(小数可。省略時は DSL 側の既定値)
    public var defaultTimeout: Double?
    /// シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。子には渡さない。省略時 600 = `ScenarioHost.defaultScenarioTimeout`)。
    /// defaultTimeout(子内部の検証待ち)とは別物
    public var scenarioTimeout: Int?
    /// iOS のモード("inapp-boost" / "xcuitest" = `IOSMode`。省略時 "inapp-boost")。devices[] で mode を明示した
    /// デバイスはそちらが優先(resolve 参照)。Android には影響しない。
    public var iosMode: String?
    /// 実行開始時に Android AVD の肥大化(wipe 対象ファイル合計サイズ)を検査し超過分を
    /// Wipe Data するか(既定 true=ON)。同期相手: vscode-fleetest/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var wipeDataOnBloat: Bool?
    /// wipeDataOnBloat のしきい値(GB、1GB=1_073_741_824 バイト。既定 8。0 以下は検証エラー。
    /// Play イメージは wipe 直後の再構築だけで userdata が 2〜4GB になるため(実測)、
    /// それ未満のしきい値は毎実行 wipe が発動するスラッシングになる — 下げるときは要注意)
    /// **テスト開始時に WebView を揃えるか**(既定 ON)。版が混在すると同じシナリオが
    /// 端末によって落ちる(124 は placeholder / 150 は #id と表現が入れ替わる)
    public var updateWebView: Bool?
    public var wipeDataThresholdGB: Double?
    /// 実行開始時に、画面凍結で CPU 描画(swiftshader)へフォールバック済みの Android エミュレータを
    /// GPU(-gpu host)で起動し直すか(既定 false=OFF)。GPU モードは emulator プロセスの起動引数で
    /// 決まるためプロセス再起動が必須で、該当機1台につき run 開始が約1分延びる。戻した先で再び凍結
    /// すればモニターの watchdog がまた CPU に落とす(DS-12.4 のトレードオフ)。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と
    /// src/monitorModel.ts の RunProfileFormFields
    public var recoverCpuFallbackToGpu: Bool?
    /// Android エミュレータのブート完了時(Wipe Data 後の再起動を含む)にブリッジ /locale で
    /// 適用するロケール(既定 "ja_JP"。Play イメージでは -change-locale 等が無効なため。
    /// DS-11.2)。iOS には影響しない。同期相手: vscode-fleetest/schemas/run-profile.schema.json
    /// と src/monitorModel.ts の RunProfileFormFields
    public var locale: String?
    /// **interop WebView 画面の委譲イベント直前にランナーへ1回接続確認(木を1回読ませる)するか**(既定 true)。
    /// attach したままの XCUITest セッションは放置後の座標イベントを 200 のまま届け損なう
    /// (実測 ~13% → 接続確認で 0/50。A/B は docs/verification/resolved.md「interop WebView」)。false で
    /// FT_PRE_ACTION_PING=0 を注入し接続確認を止める(WebViewDelegatingDriver が受ける)。
    /// 効くのは inapp-boost モードの domInterop 経路だけ(xcuitest モードには元から不要)
    public var iosPreActionPing: Bool?
    /// **容器の推測に依存する補正**を行うか(既定 true)。false にすると見切れ判定・掴み直し・
    /// 救済ドラッグ・見えている部分を撃つ座標補正・壊れた座標の候補除外が止まり、
    /// 推測を持たなかった頃の挙動へ戻る。**FM とは無関係**(幾何ヒューリスティック)。
    /// シナリオ側は `tap(..., containerInference:)` で1コマンド単位に上書きできる
    public var containerInference: Bool?
    /// テスト対象アプリのアニメーションを残すか(既定 false = 実行開始時に無効化する)。
    /// true で FT_ANIMATIONS=1 を実行環境に注入する(判定元は AnimationPolicy)。ON にすると
    /// 整定待ちが伸び、Android では静穏判定後もスクリーンショットが遷移途中の絵を掴みうる。
    /// 端末側の設定は run 開始時に毎回この値へ同期される(ブリッジ再利用でも効く)。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と
    /// src/monitorProfileForms.ts の RunProfileFormFields
    public var enableAnimations: Bool?
    /// **レスポンス計測モード**(既定 false。実験的)。true の間は実機の Android 1 台だけを対象に、
    /// 操作の反応時間を測る(docs/response-measurement.md)。`ProfileResolver.resolve` が検査し、
    /// アニメーションを残して FM・OCR の可視性検証・画面の録画・ホスト負荷による減速を止める。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と
    /// src/monitorProfileForms.ts の RunProfileFormFields
    public var responseMeasurement: Bool?
    /// 計測モードで各シナリオを続けて回す回数(既定 `ResponseMeasurementPolicy.defaultRepeat`。
    /// 範囲は 2...50 = `ResponseMeasurementPolicy.validate`)。`responseMeasurement` が true のときだけ指定できる。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と
    /// src/monitorProfileForms.ts の RunProfileFormFields
    public var responseRepeat: Int?
    /// run 開始時に各デバイスへ home() を1回撃つか(**既定 true**)。
    /// 一斉に launch した直後の端末は「描画要求が無いだけ」で画面が黒いまま止まることがあり、
    /// そのままだと凍結と見分けが付かない(実測: 黒かった5台のうち4台は入力で戻った)。
    /// 予防として1回だけ入力を入れる。**デバイスあたり1回**なので実行時間への影響はほぼゼロ。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と RunProfileFormFields
    public var homeOnStart: Bool?
    /// 各シナリオの launchApp / restartApp のたびに直後に `rotateTo` する向き(`portrait` / `landscape` =
    /// DSL の `rotateTo` と同じ語彙。**既定は指定なし = 向きに触らない**)。シナリオの終わりには rotateTo の復元が元へ戻す。
    /// 起動し直すと残らない経路(iOS inapp-boost)があるので毎回撃つ。profile-less でも `--set orientation=` で効く。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json
    public var orientation: String?
    /// 各シナリオの開始時に端末へ設定する外観(`light` / `dark`)。**既定は指定なし = 基準の状態(ライト)**。シナリオの終わりに基準へ戻す
    /// (DR-221)。iOS は Simulator も実機も `devicectl`・Android は `cmd uimode night`。profile-less でも `--set appearance=` で効く。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json
    public var appearance: String?
    /// 各シナリオの開始時の文字サイズ(`small` / `default` / `large` / `extraLarge` / `accessibility`)。**既定は指定なし = 標準(`default`)**。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json
    public var textSize: String?
    /// Android の `adb install` で Play Protect の照会を通さないか(**既定 true**)。true で
    /// install の間だけ `verifier_verify_adb_installs` を 0 にして元へ戻す(AdbInstallVerifier。
    /// テスト対象アプリを Google へ送らない = ユーザー決定)。**false はキルスイッチ**:
    /// ツールは端末の設定に触らず、release 署名の APK は端末側のダイアログで install が止まったまま
    /// になる(ツールはそのダイアログに答えない)。FT_PLAY_PROTECT_BYPASS で実行環境へ注入する。
    /// 同期相手: vscode-fleetest/schemas/run-profile.schema.json と RunProfileFormFields
    public var playProtectBypass: Bool?
    /// 並列実行の各ワーカー(デバイス)ごとに run 全体を録画し、テスト関数(シナリオ)ごとに
    /// 1本の mp4 へ切り出すか(**既定 true**。profile-less は false = `profileLessBase`)。実体は RunOrchestrator への VideoRecordingConfig 注入
    /// (VideoRecordingCoordinator.swift)。録画失敗は run を失敗させない(警告ログのみ)
    public var record: Bool?
    /// true なら成功したシナリオのクリップは保存せず、失敗(frozen 含む)シナリオのみ切り出す
    /// (既定 false = 全シナリオ保存)。record:false のときは無関係
    public var recordFailuresOnly: Bool?
    /// クリップ再エンコードの目標 bitrate(kbps。既定 1000 = VideoRecordingConfig.defaultBitrateKbps)。AVVideoAverageBitRateKey と
    /// Android screenrecord --bit-rate の両方に適用(*1000 して bps に変換)
    public var recordBitrateKbps: Int?
    /// true なら半分解像度化をスキップしフル解像度のまま出力する(既定 false)。
    /// Android は screenrecord 自体の --size 指定も省略する(録画元から既にフル解像度になる)
    public var recordFullResolution: Bool?
    /// ワークスペース(ファイル同期)宣言。省略可(既定 = リポジトリルート基準)
    public var remoteControl: RemoteControlSection?

    public init(app: String? = nil, devices: [RunDeviceEntry]? = nil,
                heal: Bool? = nil, fmTextVisibilityCheck: Bool? = nil, screenLooksLike: Bool? = nil,
                ocrTextVisibilityCheck: Bool? = nil,
                preferCheckStateClassifier: Bool? = nil,
                reportDir: String? = nil, defaultTimeout: Double? = nil, scenarioTimeout: Int? = nil,
                iosMode: String? = nil,
                wipeDataOnBloat: Bool? = nil, updateWebView: Bool? = nil,
                wipeDataThresholdGB: Double? = nil,
                recoverCpuFallbackToGpu: Bool? = nil,
                locale: String? = nil, iosPreActionPing: Bool? = nil,
                containerInference: Bool? = nil,
                enableAnimations: Bool? = nil, responseMeasurement: Bool? = nil, responseRepeat: Int? = nil,
                homeOnStart: Bool? = nil, orientation: String? = nil,
                appearance: String? = nil, textSize: String? = nil,
                playProtectBypass: Bool? = nil, record: Bool? = nil,
                recordFailuresOnly: Bool? = nil, recordBitrateKbps: Int? = nil,
                recordFullResolution: Bool? = nil, remoteControl: RemoteControlSection? = nil) {
        self.app = app
        self.devices = devices
        self.heal = heal
        self.fmTextVisibilityCheck = fmTextVisibilityCheck
        self.screenLooksLike = screenLooksLike
        self.ocrTextVisibilityCheck = ocrTextVisibilityCheck
        self.preferCheckStateClassifier = preferCheckStateClassifier
        self.reportDir = reportDir
        self.defaultTimeout = defaultTimeout
        self.scenarioTimeout = scenarioTimeout
        self.iosMode = iosMode
        self.wipeDataOnBloat = wipeDataOnBloat
        self.updateWebView = updateWebView
        self.wipeDataThresholdGB = wipeDataThresholdGB
        self.recoverCpuFallbackToGpu = recoverCpuFallbackToGpu
        self.locale = locale
        self.iosPreActionPing = iosPreActionPing
        self.containerInference = containerInference
        self.enableAnimations = enableAnimations
        self.responseMeasurement = responseMeasurement
        self.responseRepeat = responseRepeat
        self.homeOnStart = homeOnStart
        self.orientation = orientation
        self.appearance = appearance
        self.textSize = textSize
        self.playProtectBypass = playProtectBypass
        self.record = record
        self.recordFailuresOnly = recordFailuresOnly
        self.recordBitrateKbps = recordBitrateKbps
        self.recordFullResolution = recordFullResolution
        self.remoteControl = remoteControl
    }


    static let knownKeys: Set<String> = [
        "app", "devices", "heal", "fmTextVisibilityCheck", "screenLooksLike", "ocrTextVisibilityCheck",
        "preferCheckStateClassifier",
        "reportDir", "defaultTimeout", "scenarioTimeout",
        "iosMode", "wipeDataOnBloat", "updateWebView", "wipeDataThresholdGB",
        "recoverCpuFallbackToGpu", "locale",
        "iosPreActionPing", "enableAnimations", "responseMeasurement", "responseRepeat", "homeOnStart", "orientation",
        "appearance", "textSize",
        "playProtectBypass",
        "containerInference",
        "record", "recordFailuresOnly", "recordBitrateKbps", "recordFullResolution", "remoteControl",
    ]

    /// `--set` が受ける値の宣言型(配列・オブジェクトは対象外 = `arrayOrObjectKeys` で別に断る)
    public enum ValueKind: Sendable, Equatable {
        case bool, int, double, string

        /// パース失敗時に名指しする期待値の文言(string は `String(rawValue)` が常に成功するため未使用)
        var expectationDescription: String {
            switch self {
            case .bool: return "\"true\" or \"false\""
            case .int: return "an integer"
            case .double: return "a number"
            case .string: return "a string"
            }
        }
    }

    /// キー→宣言型の**唯一の定義元**。`overridableKeys`(Set)はここから導出し、
    /// `RunProfileSetOverride.parse` の型別パース分岐もここを見る。新しいスカラー欄を足したら
    /// ここと `applyingOverrides` の switch 分岐の両方に追記する(`RunProfileSetOverrideKeysTests` が
    /// Mirror で等号を固定する)
    fileprivate static let overridableKeyKinds: [String: ValueKind] = [
        "heal": .bool, "fmTextVisibilityCheck": .bool,
        "screenLooksLike": .bool, "ocrTextVisibilityCheck": .bool, "preferCheckStateClassifier": .bool,
        "iosPreActionPing": .bool,
        "containerInference": .bool, "enableAnimations": .bool, "responseMeasurement": .bool, "homeOnStart": .bool,
        "playProtectBypass": .bool, "updateWebView": .bool, "wipeDataOnBloat": .bool,
        "recoverCpuFallbackToGpu": .bool, "record": .bool, "recordFailuresOnly": .bool,
        "recordFullResolution": .bool,
        "reportDir": .string, "defaultTimeout": .double, "scenarioTimeout": .int,
        "recordBitrateKbps": .int, "responseRepeat": .int, "app": .string, "locale": .string, "iosMode": .string,
        "orientation": .string, "wipeDataThresholdGB": .double, "appearance": .string, "textSize": .string,
    ]

    /// 配列・オブジェクトの欄。`key=value` で表せないので専用のエラーで断る(未知キー扱いにしない)
    fileprivate static let arrayOrObjectKeys: Set<String> = ["devices", "remoteControl"]

    /// `fleetest run --set <key>=<value>` / `fleetest api run --set` が受け付けるキー全部
    /// (Bool 18 + スカラー11。キー名はプロファイル JSON のキーそのもの ——
    /// kebab 変換をしない)。**`RunProfileDocument` の Bool/String/Int/Double 欄の全部から
    /// `devices`・`remoteControl`(配列・オブジェクトで `key=value` を持たない)を除いたもの**。
    /// この等号は `RunProfileSetOverrideKeysTests` が Mirror で固定する
    public static let overridableKeys: Set<String> = Set(overridableKeyKinds.keys)

    /// `--set` の上書きを当てる唯一の箇所。**呼び出しは「読み込んだ直後・解決(ResolvedProfile)
    /// より前」であること**(`ProfileResolver.resolve` が守る) —— そうすれば全キーが
    /// 同じ経路で効き、消費側(ResolvedProfile の各フィールド)を個別に配線し直さずに済む。
    /// **未知キー・型の合わない値はここに来ない前提**(CLI 側が `RunProfileSetOverride.parse` で
    /// キーごとの宣言型に対して検証済み。防御的に無視するだけで、ここでは弾かない)
    public func applyingOverrides(_ overrides: [String: RunProfileSetValue]) -> RunProfileDocument {
        guard !overrides.isEmpty else { return self }
        var copy = self
        for (key, value) in overrides {
            switch (key, value) {
            case ("heal", .bool(let v)): copy.heal = v
            case ("fmTextVisibilityCheck", .bool(let v)): copy.fmTextVisibilityCheck = v
            case ("screenLooksLike", .bool(let v)): copy.screenLooksLike = v
            case ("ocrTextVisibilityCheck", .bool(let v)): copy.ocrTextVisibilityCheck = v
            case ("preferCheckStateClassifier", .bool(let v)): copy.preferCheckStateClassifier = v
            case ("iosPreActionPing", .bool(let v)): copy.iosPreActionPing = v
            case ("containerInference", .bool(let v)): copy.containerInference = v
            case ("enableAnimations", .bool(let v)): copy.enableAnimations = v
            case ("responseMeasurement", .bool(let v)): copy.responseMeasurement = v
            case ("homeOnStart", .bool(let v)): copy.homeOnStart = v
            case ("orientation", .string(let v)): copy.orientation = v
            case ("appearance", .string(let v)): copy.appearance = v
            case ("textSize", .string(let v)): copy.textSize = v
            case ("playProtectBypass", .bool(let v)): copy.playProtectBypass = v
            case ("updateWebView", .bool(let v)): copy.updateWebView = v
            case ("wipeDataOnBloat", .bool(let v)): copy.wipeDataOnBloat = v
            case ("recoverCpuFallbackToGpu", .bool(let v)): copy.recoverCpuFallbackToGpu = v
            case ("record", .bool(let v)): copy.record = v
            case ("recordFailuresOnly", .bool(let v)): copy.recordFailuresOnly = v
            case ("recordFullResolution", .bool(let v)): copy.recordFullResolution = v
            case ("reportDir", .string(let v)): copy.reportDir = v
            case ("defaultTimeout", .double(let v)): copy.defaultTimeout = v
            case ("scenarioTimeout", .int(let v)): copy.scenarioTimeout = v
            case ("recordBitrateKbps", .int(let v)): copy.recordBitrateKbps = v
            case ("responseRepeat", .int(let v)): copy.responseRepeat = v
            case ("app", .string(let v)): copy.app = v
            case ("locale", .string(let v)): copy.locale = v
            case ("iosMode", .string(let v)): copy.iosMode = v
            case ("wipeDataThresholdGB", .double(let v)): copy.wipeDataThresholdGB = v
            default: break
            }
        }
        return copy
    }
}

/// `--set <key>=<value>` のパース結果。`RunProfileDocument.ValueKind` のケースと1:1
public enum RunProfileSetValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// `--set <key>=<token>` の再構成に使う文字列表現(parse() の逆変換)。リモート
    /// ディスパッチ/フリート/マシン別サブ実行の子プロセスへ引数として渡し直すときに使う
    /// (Sources/FTRemote/RemoteDispatch.swift・Sources/fleetest/FleetRunner.swift 等)
    public var token: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// テストの `["heal": true]` 表記(暗黙のリテラル推論)を保つための組み込み。true/false の
/// トークンは他のケースと衝突しないので曖昧さは生まれない(Int/Double/String はテストでも
/// 明示的に `.int(_)`/`.double(_)`/`.string(_)` で書く)
extension RunProfileSetValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// `--set <key>=<value>` の1トークンのデコード失敗。CLI 層(`fleetest run`/`fleetest api run`。
/// 両方が同じ口を呼ぶ ——共通フラグなので `RunCommandFlagParityTests` の対象外)がそのまま
/// `ValidationError` へ包んで投げる
public enum RunProfileSetOverrideError: Error, LocalizedError {
    case invalidFormat(String)
    case invalidValue(key: String, value: String, expected: RunProfileDocument.ValueKind)
    case unknownKey(String, available: [String])
    /// `devices`/`remoteControl`(配列・オブジェクト)は `key=value` で表せない
    case arrayOrObjectKey(String)
    /// 型は合っているが範囲外(`scenarioTimeout` の負値・0 / `defaultTimeout` の負値・NaN)。
    /// `invalidValue` と分けるのは、型不一致(整数の場所に文字列)と範囲外(整数だが 0 以下)を
    /// 同じ文言で混ぜると「何が悪いか」が伝わらないため
    case outOfRange(key: String, value: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let token):
            return "--set \(token) is not <key>=<value>"
        case .invalidValue(let key, let value, let expected):
            return "--set \(key)=\(value): the value must be \(expected.expectationDescription)"
        case .unknownKey(let key, let available):
            return "--set \(key): unknown key (available: \(available.joined(separator: ", ")))"
        case .arrayOrObjectKey(let key):
            return "--set \(key): \"\(key)\" is a list/object field in the run profile and cannot be"
                + " expressed as <key>=<value> on the command line — edit the run profile JSON instead"
        case .outOfRange(let key, let value, let reason):
            return "--set \(key)=\(value): \(reason)"
        }
    }
}

/// `--set` トークン列の検証つきデコード(`fleetest run`/`fleetest api run` の共有実装)
public enum RunProfileSetOverride {
    /// 同じキーの重複指定は後勝ち(左→右の順で辞書に上書きするだけ)
    public static func parse(_ tokens: [String]) throws -> [String: RunProfileSetValue] {
        var result: [String: RunProfileSetValue] = [:]
        for token in tokens {
            guard let separator = token.firstIndex(of: "=") else {
                throw RunProfileSetOverrideError.invalidFormat(token)
            }
            let key = String(token[token.startIndex..<separator])
            let rawValue = String(token[token.index(after: separator)...])
            guard let kind = RunProfileDocument.overridableKeyKinds[key] else {
                if RunProfileDocument.arrayOrObjectKeys.contains(key) {
                    throw RunProfileSetOverrideError.arrayOrObjectKey(key)
                }
                throw RunProfileSetOverrideError.unknownKey(
                    key, available: RunProfileDocument.overridableKeys.sorted())
            }
            switch kind {
            case .bool:
                guard let value = Bool(rawValue) else {
                    throw RunProfileSetOverrideError.invalidValue(key: key, value: rawValue, expected: .bool)
                }
                result[key] = .bool(value)
            case .int:
                guard let value = Int(rawValue) else {
                    throw RunProfileSetOverrideError.invalidValue(key: key, value: rawValue, expected: .int)
                }
                // scenarioTimeout はホストの watchdog(ScenarioHost.watchdogDuration)の秒数。
                // 0 以下は「即タイムアウト」で実質シナリオを一切走らせない意味の無い値
                if key == "scenarioTimeout", value < 1 {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: "must be a positive number of seconds")
                }
                if key == "recordBitrateKbps", !(1...RunProfileDocument.maxRecordBitrateKbps).contains(value) {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue,
                        reason: "must be between 1 and \(RunProfileDocument.maxRecordBitrateKbps) (kbps)")
                }
                result[key] = .int(value)
            case .double:
                guard let value = Double(rawValue) else {
                    throw RunProfileSetOverrideError.invalidValue(key: key, value: rawValue, expected: .double)
                }
                // defaultTimeout は DSL コマンドの検証待ち秒。**0 は正当**(初回スナップショットだけを見る。
                // ステップの `timeout: 0` と同じ意味・docs/commands.md)。負値・NaN(`Double("nan")` は
                // 成功する)・無限大は下流の待ち処理を壊すので断る
                if key == "defaultTimeout", !(value >= 0 && value.isFinite) {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: "must be a non-negative, finite number of seconds (0 = the first snapshot only, no waiting)")
                }
                result[key] = .double(value)
            case .string:
                // reportDir の空文字は resolvePath で基準ディレクトリそのものになり、レポートが散らばる
                if key == "reportDir", RunProfileDocument.isBlankReportDir(rawValue) {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: "must not be empty (omit it to use reports/)")
                }
                if key == "orientation", FTOrientation.parse(rawValue) == nil {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: RunProfileDocument.orientationRule)
                }
                if key == "appearance", FTAppearance.parse(rawValue) == nil {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: FTAppearance.rule)
                }
                if key == "textSize", FTTextSize.parse(rawValue) == nil {
                    throw RunProfileSetOverrideError.outOfRange(
                        key: key, value: rawValue, reason: FTTextSize.rule)
                }
                result[key] = .string(rawValue)
            }
        }
        return result
    }
}

extension RunProfileDocument {
    /// `overridableKeys` のうち**プロファイルの devices 一覧と供給工程(AVD の起床・入れ替え)を
    /// 必要とし、他のプロファイル欄にも依存する**もの。`--set` にこれが混ざっていて `--profile` も
    /// 無いときは、黙って無視せず名指しでエラーにする(呼び出しは RunScenarios.validate /
    /// ApiRunCommand.run)。残りのキーは `DeviceIndependentRunSettings` を経由して `--profile` 無しでも
    /// 同じ経路で効く(`record`/`recordFailuresOnly`/`recordFullResolution`/`homeOnStart`/`reportDir`/
    /// `defaultTimeout`/`scenarioTimeout`/`recordBitrateKbps` も含む —— これらは devices への
    /// 前処理ではなく単に workers/レポート出力先に対して働くだけなので profile-less でも配線できる)。
    /// **`app` は「他のプロファイルを名指して読み込む」キーそのもの**(プロファイル無しでは
    /// 意味を持たない)。**`locale`/`wipeDataThresholdGB`** は Android の供給工程(wipe data)でしか
    /// 使わない(`wipeDataOnBloat` と同じ理由)
    public static let profileOnlyKeys: Set<String> = [
        "iosMode", "updateWebView", "wipeDataOnBloat", "recoverCpuFallbackToGpu",
        "app", "locale", "wipeDataThresholdGB",
        // 実機 1 台の検査が devices 一覧に依存する(ProfileResolver.resolve)
        "responseMeasurement", "responseRepeat",
    ]

    /// `record:true` は devices 一覧に依存しない(`profileOnlyKeys` に無い)が、録画の
    /// セッション管理は RunOrchestrator(VideoRecordingCoordinator)が持つため、これを経由しない
    /// 実行経路では録画できない。呼び出し側(Fleetest.swift の runSequential/runParallel 分岐・
    /// ApiRunCommand.swift の runDirect)が「この run は RunOrchestrator を経由するか」を渡す。
    /// true(=エラーにすべき)を黙って無視すると「指定したのに何も録れない」緑の run ができる
    public static func recordNeedsRejecting(record: Bool, hasRecordingSession: Bool) -> Bool {
        record && !hasRecordingSession
    }

    /// `orientation` の値の規則(`--set`・解決・単体検査で同じ文言)
    public static let orientationRule = "must be one of "
        + FTOrientation.allCases.map(\.rawValue).joined(separator: "/")
        + " (the same values as rotateTo)"

    /// `reportDir` / `--report-dir` が空(空白のみ含む)か。resolve・`--set`・専用フラグ・validate-profile の判定の唯一の定義元
    public static func isBlankReportDir(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// recordBitrateKbps の上限。根拠: `screenrecord --bit-rate` は bps の32ビット整数で、使う側が `* 1000` するため、
    /// `Int.max / 1000` を超える値は掛け算で trap し、`Int32.max / 1000` を超える値は screenrecord が受け付けない。
    /// 超えた指定は 0 以下と同じく既定へ落とす(`--set` は事前に断る)
    public static let maxRecordBitrateKbps = Int(Int32.max) / 1000

    /// 0 以下の指定は無意味なので既定へ落とす。`ProfileResolver.resolve`(--profile あり)と
    /// profile-less の録画構成(Fleetest.swift が `DeviceIndependentRunSettings.recordBitrateKbps`
    /// から組み立てる)が同じ既定(`VideoRecordingConfig.defaultBitrateKbps`)を共有する唯一の定義元
    public static func effectiveRecordBitrateKbps(_ raw: Int?) -> Int {
        raw.map { (1...maxRecordBitrateKbps).contains($0) ? $0 : VideoRecordingConfig.defaultBitrateKbps }
            ?? VideoRecordingConfig.defaultBitrateKbps
    }

    /// 専用フラグ(`--report-dir` 等)と同じ意味の `--set <key>=...` が両方指定されたときの
    /// 拒否メッセージ(`nil` = 衝突なし)。**黙ってどちらかを勝たせない** ——
    /// `fleetest run`(reportDir)/`fleetest api run`(reportDir/defaultTimeout/scenarioTimeout)が
    /// それぞれ自分の持つ専用フラグの分だけ呼ぶ。**`--app-id`/`--runner` はここでは扱わない** ——
    /// CLI の `--app-id`/`--runner` とプロファイルキー `app` は別物(前者は
    /// プロファイル無しの実行のアプリ/ディスパッチ先、後者はアプリ**プロファイル名**)
    public static func flagOverrideCollision(
        flag: String, key: String, flagIsSet: Bool, overrides: [String: RunProfileSetValue]
    ) -> String? {
        guard flagIsSet, overrides[key] != nil else { return nil }
        return "\(flag) and --set \(key)=... both set the same field; use only one"
    }
}

/// `RunProfileDocument` のうち**デバイス一覧を経由せず決まる**実効設定。`ProfileResolver.resolve`
/// (デバイスあり)と `--profile` 無しの直接実行(`RunScenarios`/`ApiRunCommand` の profile-less パス)の
/// **両方がこれを呼ぶ** —— FM の子トグルからの合成を二重に書かない。デバイス依存の欄
/// (`RunProfileDocument.profileOnlyKeys`)はここに無い
public struct DeviceIndependentRunSettings: Sendable, Equatable {
    public let fm: FMConfig
    /// ロケータ自己修復(指紋照合)。**`fm` の配下ではない**(FM を使わないので、FM を切っても止めない)
    public let heal: Bool
    public let ocrTextVisibilityCheck: Bool
    /// RunProfileDocument.preferCheckStateClassifier(**既定 true**)
    public let preferCheckStateClassifier: Bool
    public let iosPreActionPing: Bool
    public let containerInference: Bool
    public let enableAnimations: Bool
    /// RunProfileDocument.responseMeasurement(既定 false)。true なら下の欄は強制値
    /// (enableAnimations=true・fm 無効・ocrTextVisibilityCheck=false・record=false)
    public let responseMeasurement: Bool
    /// RunProfileDocument.responseRepeat(既定 `ResponseMeasurementPolicy.defaultRepeat`。計測モードのときだけ使う)
    public let responseRepeat: Int
    public let playProtectBypass: Bool
    /// run 開始時に各デバイスへ home() を撃つか(RunProfileDocument.homeOnStart。**既定 true**)
    public let homeOnStart: Bool
    /// 各ワーカーを run 全体で録画し、シナリオごとに切り出すか(RunProfileDocument.record。**既定 true**。profile-less は false)
    public let record: Bool
    /// 成功したシナリオのクリップを保存しないか(RunProfileDocument.recordFailuresOnly。既定 false)
    public let recordFailuresOnly: Bool
    /// 半分解像度化をスキップするか(RunProfileDocument.recordFullResolution。既定 false)
    public let recordFullResolution: Bool
    /// レポート出力先(RunProfileDocument.reportDir)。**未指定(nil)のときの既定は呼び出し側が持つ**
    /// (Bool 欄と違いここでは既定値へ倒さない ——「reports」相対 or 絶対のどちらもプロジェクト
    /// ルート基準で解決するのは呼び出し側の責務)
    public let reportDir: String?
    /// DSL コマンドの既定タイムアウト秒(RunProfileDocument.defaultTimeout)。未指定は呼び出し側の既定
    public let defaultTimeout: Double?
    /// シナリオ単位の壁時計タイムアウト秒(RunProfileDocument.scenarioTimeout)。未指定は呼び出し側の既定
    public let scenarioTimeout: Int?
    /// 録画クリップの再エンコード bitrate(kbps。RunProfileDocument.recordBitrateKbps)。
    /// 未指定は `VideoRecordingConfig.defaultBitrateKbps`
    public let recordBitrateKbps: Int?
    /// RunProfileDocument.orientation(既定 nil = 向きに触らない)。**既定値付きの `var`**(memberwise init を直に呼ぶ既存テストのため)
    public var orientation: FTOrientation? = nil
    /// RunProfileDocument.appearance / textSize(既定 nil = 指定なし)。既定値付きの `var`(memberwise init を直に呼ぶ既存テストのため)
    public var appearance: FTAppearance? = nil
    public var textSize: FTTextSize? = nil

    /// `--profile` を使わない実行(`--port`/`--serial` 直指定)の基底。**プロファイルの既定を
    /// そのまま使わない** —— 3つだけ意図的に違う(`fmTextVisibilityCheck` はプロファイルと同じ既定 true。
    /// ユーザー決定):
    ///   `heal` … profile-less は**修復しない**(`ScenarioExecutionSettings.init` の既定と同じ。
    ///     素の run で壊れたセレクタを黙って別要素へ解決させない)
    ///   `homeOnStart` … profile-less は**デバイスに触らない**。この設定は一斉起動直後の
    ///     黒画面を防ぐためのもので、既に起動しているブリッジへ繋ぐだけの経路では、手で用意した
    ///     画面を Home で流してしまう
    ///   `record` … profile-less は**録画しない**。録画のセッションは RunOrchestrator が持ち、この経路の
    ///     大半は通らないので、既定 true のままだと `recordNeedsRejecting` で run ごと断られる
    /// **`--set` はこの基底の上に当てる**ので、`--set heal=true` はそのまま効く。
    /// 既定はリテラルで固定するテストを置くこと(`DeviceIndependentRunSettingsTests`)
    public static let profileLessBase = RunProfileDocument(
        heal: false, homeOnStart: false, record: false)

    public static func resolve(_ doc: RunProfileDocument) -> DeviceIndependentRunSettings {
        // FM を使うかは子トグルから導く(親スイッチは無い)。両方 false なら
        // 実行バイナリへ --no-fm が渡る(ScenarioHost の既存分岐。FMConfig の doc コメント参照)
        let fmTextVisibilityCheck = doc.fmTextVisibilityCheck ?? true
        let screenLooksLike = doc.screenLooksLike ?? true
        // 計測モードは明示の true を ProfileResolver が先に断っているので、ここは既定の true を落とすだけ
        let measuring = doc.responseMeasurement ?? false
        let fmOn = !measuring && (fmTextVisibilityCheck || screenLooksLike)
        return DeviceIndependentRunSettings(
            fm: FMConfig(
                enabled: fmOn,
                fmTextVisibilityCheck: !measuring && fmTextVisibilityCheck,
                screenLooksLike: !measuring && screenLooksLike),
            heal: doc.heal ?? true,
            ocrTextVisibilityCheck: !measuring && (doc.ocrTextVisibilityCheck ?? true),
            preferCheckStateClassifier: doc.preferCheckStateClassifier ?? true,
            iosPreActionPing: doc.iosPreActionPing ?? true,
            containerInference: doc.containerInference ?? true,
            enableAnimations: measuring || (doc.enableAnimations ?? false),
            responseMeasurement: measuring,
            responseRepeat: doc.responseRepeat ?? ResponseMeasurementPolicy.defaultRepeat,
            playProtectBypass: doc.playProtectBypass ?? true,
            homeOnStart: doc.homeOnStart ?? true,
            record: !measuring && (doc.record ?? true),
            recordFailuresOnly: doc.recordFailuresOnly ?? false,
            recordFullResolution: doc.recordFullResolution ?? false,
            reportDir: doc.reportDir,
            defaultTimeout: doc.defaultTimeout,
            scenarioTimeout: doc.scenarioTimeout,
            recordBitrateKbps: doc.recordBitrateKbps,
            orientation: doc.orientation.flatMap(FTOrientation.parse),
            appearance: doc.appearance.flatMap(FTAppearance.parse),
            textSize: doc.textSize.flatMap(FTTextSize.parse))
    }
}
