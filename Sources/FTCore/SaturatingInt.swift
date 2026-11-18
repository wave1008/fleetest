// SaturatingInt.swift
// 木の幾何(枠・点)を整数へ写すときの変換。`Int(Double)` は非有限と Int の範囲外でトラップし、
// シナリオのプロセスごと落ちてレポートも残らない(iOS の in-app ブリッジが `CGRect.infinite` 相当の枠
// = 原点 ≈ -9e307 を返した要素で実際に落ちた)。木の値は外から来るので範囲を仮定しない。
// 幾何由来の `Int(...)` を素で書かないことは `SaturatingIntScanTests` がソース走査で止める

extension Int {
    /// NaN は 0、範囲外は Int.min / Int.max に寄せる(小数部は切り捨て = `Int(_:)` と同じ)
    public init<F: BinaryFloatingPoint>(saturating value: F) {
        if value.isNaN {
            self = 0
        } else if value >= F(Int.max) {
            self = .max
        } else if value <= F(Int.min) {
            self = .min
        } else {
            self = Int(value)
        }
    }
}
