// tapAppIcon(FTDSL)が「名前は一致したが一覧の縁で切れて撃てない」アイコンを見える位置へ戻す口。
// ドロワーを末尾まで送ると先頭側の行が一覧の上端で切れて縮み(Pixel 3a: 316px → 88px)、送り続けても戻らない。

extension StepExecutor {
    /// 一覧の縁で切れた一致候補を、慣性を出さないドラッグで容器の 40% 位置へ戻す(`recoveryJump` / `slowDrag` = 探索の救済と同じ部品)。
    /// 切れた候補が無い・容器が取れない・ドラッグを撃てなかったら false(呼び手は従来の探索を続ける)。
    /// 覆いで撃てない候補は対象外(送っても覆いは動かない)
    public func revealClippedAppIcon(named name: String, in snapshot: SnapshotResponse) async -> Bool {
        for icon in AppIconLocator.matches(name, in: snapshot) {
            guard let container = TapTargetGeometry.containerClippingAnyType(icon, in: snapshot.elements),
                  let jump = Self.recoveryJump(for: icon, container: container.frame),
                  let area = Self.visibleDragArea(container.frame, in: snapshot) else { continue }
            var phase = PhaseAccumulator()
            if await slowDrag(jump: jump, container: area, avoidingPressablesIn: snapshot.elements, phase: &phase) {
                return true
            }
        }
        return false
    }
}
