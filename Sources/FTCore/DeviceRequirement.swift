import Foundation

/// @RequiresDevice / @ExcludesDevice の条件1つ。判定は `DeviceRequirementMatch` に1箇所だけ置く。
public enum DeviceCondition: Codable, Equatable, Hashable, Sendable {
    case foldable
    case physical
    case virtual
    case homeButton
    /// platform は "ios" / "android"。version は "18" / "17.4"(ドット区切りの非負整数)
    case minOS(platform: String, version: String)
    /// `ValuePattern`(`||` と `*`)。台の機種名に当てる
    case model(String)
    /// `ValuePattern`。正規化した OS 文字列(`"iOS x.y[.z]"` / `"Android x"`)に当てる。全分岐が OS 名で始まること
    case os(String)

    /// DSL の書き方どおりの表記(失敗文・診断用。`.minOS(ios: "18")` 等)。FTDSLMacros の `DeviceConditionSpec.described` と同じ綴り
    public var described: String {
        switch self {
        case .foldable: return ".foldable"
        case .physical: return ".physical"
        case .virtual: return ".virtual"
        case .homeButton: return ".homeButton"
        case .minOS(let platform, let version): return ".minOS(\(platform): \"\(version)\")"
        case .model(let p): return ".model(\"\(p)\")"
        case .os(let p): return ".os(\"\(p)\")"
        }
    }

    static let osPrefixes: [(platform: String, prefix: String)] = [("ios", "iOS "), ("android", "Android ")]

    /// 宣言時の検査(英語の事実)。プラットフォームの無い `.os("17*")` はここで断る(どの OS の台にも当たりうる曖昧さを残さない)
    public static func declarationError(_ c: DeviceCondition) -> String? {
        switch c {
        case .foldable, .physical, .virtual, .homeButton:
            return nil
        case .minOS(let platform, let version):
            guard osPrefixes.contains(where: { $0.platform == platform }) else {
                return "minOS: platform \"\(platform)\" must be \"ios\" or \"android\""
            }
            guard DeviceVersion.parse(version) != nil else {
                return "minOS: version \"\(version)\" must be dot-separated non-negative integers (e.g. \"18\" or \"17.4\")"
            }
            return nil
        case .model(let pattern):
            return ValuePattern.patternError(pattern, argument: "model")
        case .os(let pattern):
            if let error = ValuePattern.patternError(pattern, argument: "os") { return error }
            for branch in ValuePattern.alternatives(pattern)
            where !osPrefixes.contains(where: { branch.hasPrefix($0.prefix) }) {
                return "os: alternative \"\(branch)\" in \"\(pattern)\" must start with \"iOS \" or \"Android \""
            }
            return nil
        }
    }

    /// `.os` のパターンが指す platform の集合(分岐ごとの接頭辞)
    static func osPlatforms(_ pattern: String) -> Set<String> {
        Set(ValuePattern.alternatives(pattern).compactMap { b in osPrefixes.first { b.hasPrefix($0.prefix) }?.platform })
    }
}

/// ドット区切りの非負整数の版(欠けた成分は 0 として比べる)
public enum DeviceVersion {
    public static func parse(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

/// クラスとテストの宣言を合わせた条件の組。required = 全部満たす / excluded = どれか1つに合えば外す(許可より優先)
public struct DeviceRequirementSet: Codable, Equatable, Hashable, Sendable {
    public var required: [DeviceCondition]
    public var excluded: [DeviceCondition]

    public init(required: [DeviceCondition] = [], excluded: [DeviceCondition] = []) {
        self.required = Self.dedup(required)
        self.excluded = Self.dedup(excluded)
    }

    public var isEmpty: Bool { required.isEmpty && excluded.isEmpty }

    /// クラスとテストの和(順序はクラス → テスト・重複は先勝ち)
    public static func merging(class classSet: DeviceRequirementSet, test: DeviceRequirementSet) -> DeviceRequirementSet {
        DeviceRequirementSet(required: classSet.required + test.required, excluded: classSet.excluded + test.excluded)
    }

    /// 宣言だけで満たせないと分かる矛盾(英語の事実)
    public var contradictions: [String] {
        var out: [String] = []
        if required.contains(.physical) && required.contains(.virtual) {
            out.append("both physical and virtual are required")
        }
        for c in required where excluded.contains(c) {
            out.append("\(c.described) is both required and excluded")
        }
        return out
    }

    private static func dedup(_ xs: [DeviceCondition]) -> [DeviceCondition] {
        var seen = Set<DeviceCondition>()
        return xs.filter { seen.insert($0).inserted }
    }
}

/// 台の性質。nil = 読めなかった(性質ごと)。
/// 空文字・`"iOS"` だけの値を値として入れない(観測側で nil にする。入れると `.unreadable` が `.unfit` に化ける)
public struct DeviceTraits: Codable, Equatable, Hashable, Sendable {
    /// "ios" / "android"
    public var platform: String
    /// プロファイルの種別から分かるので常に確定
    public var physical: Bool
    public var foldable: Bool?
    public var homeButton: Bool?
    /// 正規化済み `"iOS 27.2"` / `"Android 17"`
    public var osVersion: String?
    public var model: String?

    public init(platform: String, physical: Bool, foldable: Bool? = nil, homeButton: Bool? = nil,
                osVersion: String? = nil, model: String? = nil) {
        self.platform = platform
        self.physical = physical
        self.foldable = foldable
        self.homeButton = homeButton
        self.osVersion = osVersion
        self.model = model
    }
}

public enum DeviceRequirementMatch {
    public enum Fit: Equatable, Sendable {
        case fits
        case unfit(reasons: [String])
        case unreadable(traits: [String])
    }

    public typealias Device = (id: String, traits: DeviceTraits)

    private enum Eval { case notBinding, matches, doesNotMatch, unreadable(String) }

    /// 判定の順: 縛る条件の性質が nil → unreadable / 除外に合う → unfit / 必須を欠く → unfit / fits
    public static func fit(_ set: DeviceRequirementSet, _ traits: DeviceTraits) -> Fit {
        var unreadable: [String] = []
        var excludedHits: [String] = []
        var requiredMisses: [String] = []
        for c in set.required {
            switch eval(c, traits) {
            case .unreadable(let t): if !unreadable.contains(t) { unreadable.append(t) }
            case .doesNotMatch: requiredMisses.append("\(c.described) is required")
            case .matches, .notBinding: break
            }
        }
        for c in set.excluded {
            switch eval(c, traits) {
            case .unreadable(let t): if !unreadable.contains(t) { unreadable.append(t) }
            case .matches: excludedHits.append("\(c.described) is excluded")
            case .doesNotMatch, .notBinding: break
            }
        }
        if !unreadable.isEmpty { return .unreadable(traits: unreadable) }
        if !excludedHits.isEmpty || !requiredMisses.isEmpty { return .unfit(reasons: excludedHits + requiredMisses) }
        return .fits
    }

    public static func partition(_ set: DeviceRequirementSet, devices: [Device])
        -> (fits: [String], unfit: [String], unreadable: [String]) {
        var r: (fits: [String], unfit: [String], unreadable: [String]) = ([], [], [])
        for d in devices {
            switch fit(set, d.traits) {
            case .fits: r.fits.append(d.id)
            case .unfit: r.unfit.append(d.id)
            case .unreadable: r.unreadable.append(d.id)
            }
        }
        return r
    }

    /// 条件の組ごとに合う台を1台(同着は識別子の辞書順で最小 = 入力順に依らない全順序)
    public static func mustKeep(sets: [DeviceRequirementSet], devices: [Device]) -> Set<String> {
        var keep = Set<String>()
        for set in Set(sets) where !set.isEmpty {
            if let id = partition(set, devices: devices).fits.min() { keep.insert(id) }
        }
        return keep
    }

    /// 事実だけ(合わなかった台とその理由・読めなかった台とその性質)。対処文は呼び手が足す
    public static func noMatchFacts(_ set: DeviceRequirementSet, devices: [Device]) -> [String] {
        devices.compactMap { d in
            switch fit(set, d.traits) {
            case .fits: return nil
            case .unfit(let reasons): return "\(d.id): unfit (\(reasons.joined(separator: "; ")))"
            case .unreadable(let traits): return "\(d.id): unreadable (\(traits.joined(separator: ", ")))"
            }
        }
    }

    private static func eval(_ c: DeviceCondition, _ t: DeviceTraits) -> Eval {
        func flag(_ v: Bool?, _ name: String) -> Eval {
            guard let v else { return .unreadable(name) }
            return v ? .matches : .doesNotMatch
        }
        switch c {
        case .physical: return t.physical ? .matches : .doesNotMatch
        case .virtual: return t.physical ? .doesNotMatch : .matches
        case .foldable: return flag(t.foldable, "foldable")
        case .homeButton: return flag(t.homeButton, "homeButton")
        case .model(let p):
            guard let m = t.model else { return .unreadable("model") }
            return ValuePattern.patternMatches(p, value: m) ? .matches : .doesNotMatch
        case .os(let p):
            guard DeviceCondition.osPlatforms(p).contains(t.platform) else { return .notBinding }
            guard let os = t.osVersion else { return .unreadable("osVersion") }
            return ValuePattern.patternMatches(p, value: os) ? .matches : .doesNotMatch
        case .minOS(let platform, let version):
            guard platform == t.platform, let want = DeviceVersion.parse(version) else { return .notBinding }
            guard let os = t.osVersion,
                  let prefix = DeviceCondition.osPrefixes.first(where: { os.hasPrefix($0.prefix) })?.prefix,
                  let have = DeviceVersion.parse(String(os.dropFirst(prefix.count)))
            else { return .unreadable("osVersion") }
            return DeviceVersion.compare(have, want) >= 0 ? .matches : .doesNotMatch
        }
    }
}
