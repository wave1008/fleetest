import SwiftUI
import UIKit

/// 長押しからのドラッグの並べ替えが効かない回の測る口: 画面のウィンドウに付けた受け身の認識器で、1本のタッチ列(began〜ended)の届き方を記録する。
/// 出す形 `trace=m<移動の数> f<最初の移動の ms> g<移動の最大の間隔 ms> l<事象の時刻から処理までの最大の遅れ ms>
/// h<メインスレッドの最大のフレーム間隔 ms> u<離した ms>`(ms はタッチの始まりから・`-` = 起きず)。判定には使わない。
/// 認識器は何も認識しない(.possible のまま終わり .failed)・`cancelsTouchesInView = false`・同時認識を許す
/// = 並べ替えの長押し・ドラッグを止めない。
final class TouchTraceRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTrace: ((String) -> Void)?
    private var began: TimeInterval = 0
    private var moves = 0
    private var firstMove: Double?
    private var lastMove: Double?
    private var maxGap: Double = 0
    private var maxLag: Double = 0
    private var maxFrame: Double = 0
    private var lastFrame: CFTimeInterval?
    private var link: CADisplayLink?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func ms(_ t: TimeInterval) -> Double { (t - began) * 1000 }

    private func noteLag(_ touches: Set<UITouch>) {
        let now = ProcessInfo.processInfo.systemUptime  // UITouch.timestamp と同じ時計(起動からの秒)
        for t in touches { maxLag = max(maxLag, (now - t.timestamp) * 1000) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard numberOfTouches <= 1, let t = touches.first else { return }
        began = t.timestamp
        moves = 0; firstMove = nil; lastMove = nil; maxGap = 0; maxLag = 0; maxFrame = 0; lastFrame = nil
        noteLag(touches)
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func frame(_ l: CADisplayLink) {
        if let lastFrame { maxFrame = max(maxFrame, (l.timestamp - lastFrame) * 1000) }
        lastFrame = l.timestamp
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        let at = ms(t.timestamp)
        moves += 1
        if firstMove == nil { firstMove = at }
        if let lastMove { maxGap = max(maxGap, at - lastMove) }
        lastMove = at
        noteLag(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        link?.invalidate(); link = nil
        noteLag(touches)
        let up = touches.first.map { ms($0.timestamp) }
        func f(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "-" }
        onTrace?("trace=m\(moves) f\(f(firstMove)) g\(f(maxGap)) l\(f(maxLag)) h\(f(maxFrame)) "
                 + (cancelled ? "c" : "u") + f(up))
        state = .failed
    }

    override func reset() {
        super.reset()
        link?.invalidate(); link = nil
    }
}

/// 背景に置くと、表示中だけそのウィンドウへ `TouchTraceRecognizer` を付ける(消えたら外す)
struct TouchTraceInstaller: UIViewRepresentable {
    let onTrace: (String) -> Void

    final class Host: UIView {
        let recognizer = TouchTraceRecognizer(target: nil, action: nil)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.isUserInteractionEnabled = false
        host.recognizer.onTrace = onTrace
        return host
    }

    func updateUIView(_ uiView: Host, context: Context) { uiView.recognizer.onTrace = onTrace }

    static func dismantleUIView(_ uiView: Host, coordinator: ()) {
        uiView.recognizer.view?.removeGestureRecognizer(uiView.recognizer)
    }
}
