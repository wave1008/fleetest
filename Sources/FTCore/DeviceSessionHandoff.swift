// DeviceSessionHandoff.swift
// デバイスセッション(run メモ = run 全体で共有・setUpDevice の済み印 = 1デバイス・beforeAll の済み印 = run 全体)の親→子の受け渡し。
// プロトコル:
//   親→子: 子を `--device-session-stdin` で起動し、stdin の**1行目**にこの DTO を NDJSON 1行で書く。
//     子は他の何より先に1行目を読む(debug / host-install の制御コマンドは2行目以降)。
//   子→親: ScenarioEvent の runMemoWrite / runMemoClear / deviceSetUp / beforeAll(ScenarioEvent.swift 冒頭)。
// 親側の状態は RunDeviceSession.swift、子側は FTDriveCore(FTDSL)。
// run メモは起動時の写し + 書き込みの片道通知。同じマシンの次のシナリオは必ず最新を受け取る(ScenarioHost が
// 子の stdout を読み切ってから戻るため)。**走っている最中のシナリオの書き込みは、そのシナリオが
// 終わる前に起動したシナリオには届かない**(写しは起動時の1回。書き込みの排他も置かない = DR-208)。
// test 範囲のメモ(writeMemo 等)は子の中だけで完結し、この受け渡しにも通知にも載らない

import Foundation

public struct DeviceSessionHandoff: Codable, Sendable, Equatable {
    /// 常に "deviceSession"(stdin の他の制御コマンドと同じく cmd で種別を示す)
    public var cmd: String
    /// run メモ: キー → 書いた順の値(履歴を持ち、readRunMemo は最後の値)
    public var runMemo: [String: [String]]
    /// true = このシナリオの前に setUpDevice を走らせる(このデバイスでこのクラスは未試行)
    public var runSetUpDevice: Bool
    /// true = このシナリオの前に beforeAll を走らせる(この run でこのクラスの beforeAll を受け持つ)
    public var runBeforeAll: Bool

    public static let command = "deviceSession"

    public init(runMemo: [String: [String]], runSetUpDevice: Bool, runBeforeAll: Bool) {
        self.cmd = Self.command
        self.runMemo = runMemo
        self.runSetUpDevice = runSetUpDevice
        self.runBeforeAll = runBeforeAll
    }

    /// stdin へ書く1行(改行は含まない)
    public func encodedLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let line = String(data: data, encoding: .utf8) else {
            return #"{"cmd":"deviceSession","runMemo":{},"runBeforeAll":false,"runSetUpDevice":false}"#
        }
        return line
    }

    /// cmd が deviceSession でない・壊れている行は nil
    public static func decode(line: String) -> DeviceSessionHandoff? {
        guard let data = line.data(using: .utf8),
              let handoff = try? JSONDecoder().decode(DeviceSessionHandoff.self, from: data),
              handoff.cmd == command else { return nil }
        return handoff
    }
}
