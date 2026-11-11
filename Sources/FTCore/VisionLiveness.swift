// この機械の Apple Vision が今**使える状態か**の、機械グローバルな台帳(OCR と特徴量は別の判定)。
//
// 動機: OCR が何時間も空を返す・特徴量が縮退する機械は、モニターの Vision の回数・失敗数だけでは
// 健全に見える(誰も呼ばなければ 0 件 = 死んでいても同じ絵)。モニターに出すための警告専用の台帳で、
// シナリオの合否には一切使わない。
//
// 規律(VideoEncoderLiveness と同じ向き):
//  ① **生 / 死 / 不明の3値**(対象ごと)。記録が無い・`freshSeconds` より古いは nil(不明)で、死と混ぜない
//  ② **書き手は根拠を名乗る**(`Source`)
//  ③ **新しい観測が勝つ**(対象ごと。読み→比較→rename は flock の内側)
//
// 置き場は ~/.fleetest/vision-liveness.json(`FT_VISION_LIVENESS_DIR` で差し替え。テスト用)。
// 読み手: `api host-metrics`(NDJSON の visionOCR* / visionFeaturePrint* → モニターのバッジ)。
// 書き手: `api host-metrics --vision-probe` だけ。**確かめは VisionUsageLedger に書かない**(実使用の回数を汚さない)。

import CoreGraphics
import Foundation
import ImageIO
import Synchronization

public enum VisionLiveness {
    public enum Subject: String, Codable, Sendable, CaseIterable {
        case ocr
        case featurePrint
    }

    public enum State: String, Codable, Sendable {
        case alive
        case dead
    }

    public enum Source: String, Codable, Sendable {
        /// 内蔵の絵での確かめ(VisionLivenessProbe)
        case probe
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public var state: State
        /// 観測した時刻(epoch 秒)
        public var checkedAt: Double
        public var source: Source
        /// 死のときの理由。生のときは nil
        public var error: String?

        public init(state: State, checkedAt: Double, source: Source, error: String? = nil) {
            self.state = state
            self.checkedAt = checkedAt
            self.source = source
            self.error = state == .dead ? error : nil
        }

        public func isFresh(now: Date = Date(), maxAge: TimeInterval = VisionLiveness.freshSeconds) -> Bool {
            let age = now.timeIntervalSince1970 - checkedAt
            return age < maxAge && age > -maxAge
        }
    }

    /// 確かめの間隔(秒)。ハードウェアエンコーダ(VideoEncoderLiveness)と同じ刻み = 故障は再起動やモデルの
    /// 不調で数分〜数時間続く形しか観測していないので 60 秒で足りる。1回の確かめは OCR 数十 ms + 特徴量 3 回
    public static let probeIntervalSeconds: TimeInterval = 60
    /// これより古い観測は「不明」。確かめの間隔の2倍 = 1回取りこぼしただけで不明にしない
    public static let freshSeconds: TimeInterval = 120
    /// 1Hz の NDJSON に載せる理由の長さ(VideoEncoderLiveness.errorLimit と同じ)
    public static let errorLimit = 200

    // MARK: - 置き場

    static let fileName = "vision-liveness.json"
    static let lockFileName = "vision-liveness.lock"
    public static let directoryOverrideKey = "FT_VISION_LIVENESS_DIR"

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent(fileName)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true).appendingPathComponent(fileName)
    }

    /// 書き込み先。nil = 書かない(LedgerWriteRole で opt-in した production の実行ファイルだけが書く。XCTest は書かない)
    static var writeURL: URL? {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent(fileName)
        }
        guard LedgerWriteRole.permitsProductionWrite else { return nil }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return fileURL
    }

    // MARK: - 書く・読む

    /// 観測1件を書く。ディスクの同じ対象の記録より古ければ書かない(③)。書き込み失敗は握りつぶす
    public static func record(_ subject: Subject, _ verdict: Verdict) {
        guard let url = writeURL else { return }
        guard let previous = write(subject, verdict, to: url) else { return }
        // 変わり目だけ残す。生は「死から戻った」ときだけ(記録が無い状態からの生は兆候ではない)
        switch verdict.state {
        case .dead where previous != .dead:
            VisionLivenessHistory.append(subject: subject, event: .becameDead, source: verdict.source, detail: verdict.error)
        case .alive where previous == .dead:
            VisionLivenessHistory.append(subject: subject, event: .becameAlive, source: verdict.source, detail: nil)
        default:
            break
        }
    }

    /// 書いたら書く前のその対象の状態を返す(.some(nil) = 記録が無かった)。書かなかった(古い・失敗)なら nil
    @discardableResult
    static func write(_ subject: Subject, _ verdict: Verdict, to url: URL) -> State?? {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(lockFileName).path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }  // close が flock も解放する
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { return nil }
        }
        var all = readAll(at: url)
        let current = all[subject.rawValue]
        if let current, current.checkedAt > verdict.checkedAt { return nil }
        var stored = verdict
        stored.error = stored.error.map { String($0.prefix(errorLimit)) }
        all[subject.rawValue] = stored
        guard let data = try? JSONEncoder().encode(all) else { return nil }
        let tmp = dir.appendingPathComponent(".\(fileName).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return .some(current?.state)
    }

    static func readAll(at url: URL) -> [String: Verdict] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Verdict].self, from: data)) ?? [:]
    }

    static func read(_ subject: Subject, at url: URL) -> Verdict? { readAll(at: url)[subject.rawValue] }

    /// 鮮度を当てた読み。nil = 不明(死と混ぜない)
    public static func current(_ subject: Subject, now: Date = Date()) -> Verdict? {
        current(subject, at: fileURL, now: now)
    }

    static func current(_ subject: Subject, at url: URL, now: Date) -> Verdict? {
        guard let verdict = read(subject, at: url), verdict.isFresh(now: now) else { return nil }
        return verdict
    }

    /// host-metrics の確かめ(`--vision-probe`)。対象ごとに、台帳が `probeIntervalSeconds` より古いときだけ撃つ
    /// 対象は並行に確かめる(OCR の最初の1回はモデルのコンパイルで最大 2 分かかり、その間 特徴量の判定を待たせない)
    public static func refreshIfStale(now: Date = Date()) async {
        await withTaskGroup(of: Void.self) { group in
            for subject in Subject.allCases {
                if let verdict = read(subject, at: fileURL), now.timeIntervalSince1970 - verdict.checkedAt < probeIntervalSeconds,
                   verdict.checkedAt <= now.timeIntervalSince1970 {
                    continue
                }
                group.addTask {
                    guard let observed = await VisionLivenessProbe.check(subject) else { return }
                    record(subject, observed)
                }
            }
        }
    }
}

/// 内蔵の絵で Vision の OCR と特徴量を確かめる。**VisionUsageLedger に書かない**(実使用の計数を汚さない。
/// OCR は `RegionText.readerIsAlive`(= 計数しない `recognizeObservations` 経由)、特徴量は
/// `FindImage.featurePrintUnrecorded`)。判定は FindImage の既存の門(`isConsistent` / `isDegenerate`)を使う。
/// 注入: `FT_FAKE_VISION_DEAD=ocr|featurePrint|all` は Vision に触らずに死を返す(観測と公表の経路だけを通す)
public enum VisionLivenessProbe {
    public static let injectionKey = "FT_FAKE_VISION_DEAD"

    /// 対象ごとの期限(秒)。超えたら死と書き、このプロセスでは以後その対象を撃たない(固着した呼び出しへ撃ち続けると
    /// スレッドが積み上がる)。**OCR はプロセスで最初の1回が認識器のコンパイルを払う**(キャッシュはプロセス名と署名ごと =
    /// fleetest を作り直すたびにコールド)ので `RegionText.modelCompileWaitCap`(正当なコンパイルの実測最大 108 秒 + 1 割)を
    /// 共有する(15 秒にした版は、作り直した直後の健全な機械で最初の確かめを死と書いた)。コンパイルの排他
    /// (`compileModelIfNeeded`)は取らない = run の開始時の compile-ocr を待たせない。
    /// 特徴量は初回のモデル読み込みも数秒で終わるが、同じ値でよい(固着の判定だけに使う)
    public static let deadlineSeconds: Double = {
        let cap = RegionText.modelCompileWaitCap.components
        return Double(cap.seconds) + Double(cap.attoseconds) / 1e18
    }()

    private static let hung = Mutex<Set<VisionLiveness.Subject>>([])

    /// 観測(生 / 死)。nil = 撃たなかった(非対応・OCR モデルのコンパイル中・固着済み = 台帳は古くなって不明になる)
    public static func check(
        _ subject: VisionLiveness.Subject,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ocrSupported: Bool = OCRSupport.isSupported,
        compileActiveCount: () -> Int = { OCRModelCompileLedger.activeCount() },
        now: @Sendable () -> Date = { Date() }
    ) async -> VisionLiveness.Verdict? {
        if isInjectedDead(subject, environment: environment) {
            return .init(state: .dead, checkedAt: now().timeIntervalSince1970, source: .probe,
                         error: "injected (\(injectionKey)=\(environment[injectionKey] ?? ""))")
        }
        if subject == .ocr, !ocrSupported { return nil }
        // コンパイル中は Vision が重く、確かめが遅れて死と誤るので撃たない
        if compileActiveCount() > 0 { return nil }
        guard !hung.withLock({ $0.contains(subject) }) else { return nil }
        let result: String?? = await DeadlineRace.first(seconds: deadlineSeconds, onTimeout: String??.none) {
            await Task.detached { await run(subject) }.value
        }
        let checkedAt = now().timeIntervalSince1970
        guard let failure = result else {
            hung.withLock { _ = $0.insert(subject) }
            return .init(state: .dead, checkedAt: checkedAt, source: .probe,
                         error: "Vision \(subject.rawValue) check did not finish within \(Int(deadlineSeconds))s")
        }
        return .init(state: failure == nil ? .alive : .dead, checkedAt: checkedAt, source: .probe, error: failure)
    }

    static func isInjectedDead(_ subject: VisionLiveness.Subject, environment: [String: String]) -> Bool {
        guard let value = environment[injectionKey] else { return false }
        return value == "all" || value == subject.rawValue
    }

    /// nil = 生。失敗は1文
    private static func run(_ subject: VisionLiveness.Subject) async -> String? {
        switch subject {
        case .ocr:
            return await RegionText.readerIsAlive() ? nil : "OCR did not read the built-in check image"
        case .featurePrint:
            return await featurePrintFailure()
        }
    }

    private static func featurePrintFailure() async -> String? {
        guard let source = CGImageSourceCreateWithData(RegionText.livenessProbePNG as CFData, nil),
              let imageA = CGImageSourceCreateImageAtIndex(source, 0, nil), let imageB = distinctImage() else {
            return "could not build the built-in check images"
        }
        do {
            let first = try await FindImage.featurePrintUnrecorded(imageA)
            let again = try await FindImage.featurePrintUnrecorded(imageA)
            let other = try await FindImage.featurePrintUnrecorded(imageB)
            let selfDistance = Double(try first.distance(to: again))
            if !FindImage.isConsistent(selfDistance: selfDistance) {
                return "the same image produced different feature prints (distance \(String(format: "%.4f", selfDistance)))"
            }
            if FindImage.isDegenerate(templateDistanceToBlank: Double(try first.distance(to: other))) {
                return "two different images produced identical feature prints (distance 0)"
            }
            return nil
        } catch {
            return "feature print request failed: \(error)"
        }
    }

    /// 内蔵の絵 A(文字の絵)と別物の絵。図形だけ(フォントを描かない = シナリオ実行バイナリの Seatbelt の中でも決定的)
    static func distinctImage() -> CGImage? {
        let side = 128
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 20, y: 30, width: 70, height: 70))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 40, height: 24))
        return context.makeImage()
    }
}
