// 撃つ点を帯(上端の安全領域・下端のジェスチャ帯)の外へ寄せる。tap / 長押し / doubleTap / holdStart が共有する

extension StepExecutor {
    /// 上端の帯の下へ寄せて撃ったときの注記(MCP は同じ事実を自分の文言で言う)
    public static let topBandTapNote = "touched the part of the element below the top safe-area band"
        + " (its centre is inside the band, where a touch goes to the system status bar / notch instead)"

    /// 押す点を帯の外へ寄せた y と注記(寄せなければ nil)。下端のジェスチャ帯(Android)→ 上端の安全領域の帯の順。
    /// 上端は木の `safeAreaTop`(申告)だけが材料でドライバへ問い合わせない
    func bandClearedTap(for frame: FTRect, snapshot: SnapshotResponse) async -> (y: Double, note: String)? {
        await bandClearedTap(for: frame, screen: snapshot.screen, safeAreaTop: snapshot.safeAreaTop)
    }

    /// 木のスナップショットを持たない呼び手(`performGesture`)用の材料渡し版
    func bandClearedTap(for frame: FTRect, screen: FTRect, safeAreaTop: SafeAreaTop) async -> (y: Double, note: String)? {
        if let y = await bottomBandTapY(for: frame, screen: screen) { return (y, Self.bottomBandTapNote) }
        if let y = TapTargetGeometry.topBandTapY(for: frame, safeAreaTop: safeAreaTop, screen: screen) {
            return (y, Self.topBandTapNote)
        }
        return nil
    }
}
