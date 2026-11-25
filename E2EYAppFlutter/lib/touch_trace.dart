import 'dart:async';

import 'package:flutter/material.dart';

import 'tags.dart';
import 'widgets.dart';

/// OI-238 の測る口(E2EY-Flutter だけ)。アプリ全体を `Listener`(translucent)で包み、左端の帯で始まった直近1本の
/// ポインタ列を `#txt_touch_trace` の1行にする。ヒットテストと既存のジェスチャは変えない。
/// 書式は E2EYAppCMP/docs/ui-contract.md「Flutter だけの測る口」。シナリオは検証しない。
/// MOVE ごとには文字を更新しない(再構築を避ける)。更新は DOWN・最初の MOVE・UP/CANCEL・戻るの再サンプル。
class TouchTrace extends StatefulWidget {
  const TouchTrace({required this.navigatorKey, required this.child, super.key});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<TouchTrace> createState() => _TouchTraceState();
}

class _TouchTraceState extends State<TouchTrace> {
  final _text = ValueNotifier<String>('trace=-');
  final _active = <int>{};
  int? _primary;
  Duration _downAt = Duration.zero;
  Offset _down = Offset.zero;
  Offset _last = Offset.zero;
  int _moves = 0;
  int? _firstMoveMs;
  int? _endMs;
  bool _cancelled = false;
  bool _gesture = false;
  Timer? _resample;

  int _ms(PointerEvent e) => (e.timeStamp - _downAt).inMilliseconds;

  void _sampleGesture() {
    if (widget.navigatorKey.currentState?.userGestureInProgress ?? false) {
      _gesture = true;
    }
  }

  static String _xy(Offset o) =>
      '${o.dx.toStringAsFixed(1)},${o.dy.toStringAsFixed(1)}';

  void _publish() {
    final end = _endMs == null ? 'u-' : '${_cancelled ? 'c' : 'u'}$_endMs';
    _text.value = 'trace=d${_xy(_down)} m$_moves f${_firstMoveMs ?? '-'} '
        'l${_xy(_last)} $end g${_gesture ? 1 : 0}';
  }

  /// 記録する列の始点の左端からの幅(論理 px)。back() の縁の払いは左端 +1pt から始まり、Flutter の
  /// Cupertino の戻るの払いが拾う縁も 20。**この帯の外で始まった列は記録しない** —— 全部のタップで文字が
  /// 変わると、木の比較・画素の指紋で「画面が変わらなかった」を見る判定がこの SUT で働かなくなる
  static const double _edgeWidth = 20;

  void _onDown(PointerDownEvent e) {
    if (_active.isEmpty && e.position.dx > _edgeWidth) {
      _primary = null;
      _active.add(e.pointer);
      return;
    }
    if (_active.isEmpty) {
      _resample?.cancel();
      _primary = e.pointer;
      _downAt = e.timeStamp;
      _down = e.position;
      _last = e.position;
      _moves = 0;
      _firstMoveMs = null;
      _endMs = null;
      _cancelled = false;
      _gesture = false;
      _sampleGesture();
      _publish();
    }
    _active.add(e.pointer);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _primary) return;
    _moves++;
    _last = e.position;
    _sampleGesture();
    if (_moves == 1) {
      _firstMoveMs = _ms(e);
      _publish();
    }
  }

  void _onEnd(PointerEvent e, {required bool cancelled}) {
    _active.remove(e.pointer);
    if (e.pointer != _primary) return;
    _last = e.position;
    _endMs = _ms(e);
    _cancelled = cancelled;
    _sampleGesture();
    _publish();
    // 戻るの払いは指を離した後に確定・巻き戻しが走るので、少し後にもう一度見る。
    _resample?.cancel();
    // 400ms = 戻るの払いの確定・巻き戻しのアニメ(Cupertino の遷移 約 350ms)が終わる頃
    _resample = Timer(const Duration(milliseconds: 400), () {
      _sampleGesture();
      _publish();
    });
  }

  @override
  void dispose() {
    _resample?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: (e) => _onEnd(e, cancelled: false),
    onPointerCancel: (e) => _onEnd(e, cancelled: true),
    child: Stack(
      children: [
        Positioned.fill(child: widget.child),
        // 右上の隅のステータスバーの帯の中の極小(48x8 論理 px)。最前面の木の要素なので、アプリの要素(下端のバー・FAB)と
        // 重なる所に置くと覆いの判定に拾われる。左端(back の払いの始点)にも置かない。
        Positioned(
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: SizedBox(
              width: 48,
              height: 8,
              child: ValueListenableBuilder<String>(
                valueListenable: _text,
                builder: (_, v, _) => tagged(
                  Tags.touchTrace,
                  Text(
                    v,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 6,
                      height: 1,
                      color: Color(0x66000000),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
