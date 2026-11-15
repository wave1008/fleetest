import SwiftUI

/// 常時編集モード(`.environment(\.editMode, .constant(.active))`)でハンドルを常に出す
/// (iOS の定番: 右端のハンドルを掴んでドラッグする形。EditButton による切替は使わない)。
struct ReorderScreen: View {
    @State private var order = Array(1...5)
    @State private var trace = "trace=-"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaggedText(tag: Tags.txtReorderResult, text: "order=" + order.map(String.init).joined(separator: ","))
                .padding([.horizontal, .top], 16)
            // OI-221 の測る口(シナリオは検証しない。赤の回の要素一覧に残す)
            TaggedText(tag: Tags.txtTouchTrace, text: trace)
                .padding(.horizontal, 16)
                .background(TouchTraceInstaller { trace = $0 })
            List {
                ForEach(order, id: \.self) { n in
                    Text("並べ替え \(n)")
                        .accessibilityIdentifier(Tags.reorderRow(n))
                }
                .onMove { indices, newOffset in
                    order.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .environment(\.editMode, .constant(.active))
        }
        .screenTitleTag("並べ替え")
    }
}
