import 'dart:async';

import 'package:flutter/material.dart';

/// OI-238 の測る口(E2EY-Flutter だけ)。アプリ全体を `Listener`(translucent)で包み、左端の帯で始まった直近1本の
/// ポインタ列を1行にして端末の統合ログへ出す(木には載せない)。ヒットテストと既存のジェスチャは変えない。
/// 書式は E2EYAppCMP/docs/ui-contract.md「Flutter だけの測る口」。シナリオは検証しない。
/// 書くのは UP/CANCEL と戻るの再サンプル(400ms 後)の2回。
class TouchTrace extends StatefulWidget {
  const TouchTrace({required this.navigatorKey, required this.child, super.key});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<TouchTrace> createState() => _TouchTraceState();
}

class _TouchTraceState extends State<TouchTrace> {
  /// 押している指の id → 押した時刻。終わりの事象がこの Listener に届かなかった指(遷移・バックグラウンドで取り消しが来ない)は
  /// 残り続けて以後の列を記録しなくなるので、押してから `_staleAfter` を過ぎた指は次の押しで捨てる
  final _active = <int, Duration>{};

  /// 根拠: シナリオの最長の押し(hold 6 秒)の5倍。これより長く押し続ける操作は無い
  static const _staleAfter = Duration(seconds: 30);
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

  /// 列の終わり(UP / CANCEL)と 400ms 後の再サンプルでだけ書く。**木には載せない** —— 木の文字を変えると、
  /// back() が効いたかを木の比較で見る判定(`BackEffect.hadNoEffect`)がこの SUT で「効いた」に倒れる
  void _publish() {
    if (_endMs == null) return;
    final end = '${_cancelled ? 'c' : 'u'}$_endMs';
    // ignore: avoid_print
    print('$_logTag trace=d${_xy(_down)} m$_moves f${_firstMoveMs ?? '-'} '
        'l${_xy(_last)} $end g${_gesture ? 1 : 0}');
  }

  /// 端末の統合ログで引く印(`xcrun simctl spawn <udid> log show --predicate 'eventMessage CONTAINS "ft-touch-trace"'`)
  static const _logTag = 'ft-touch-trace:';

  /// 記録する列の始点の左端からの幅(論理 px)。back() の縁の払いは左端 +1pt から始まり、Flutter の
  /// Cupertino の戻るの払いが拾う縁も 20。この帯の外で始まった列は記録しない(back() の材料だけを残し、ログを埋めない)
  static const double _edgeWidth = 20;

  void _onDown(PointerDownEvent e) {
    _active.removeWhere((_, at) => e.timeStamp - at > _staleAfter);
    if (_active.isEmpty) _resample?.cancel(); // 前の列の再サンプルが新しい列の戻るのジェスチャを拾わないように
    if (_active.isEmpty && e.position.dx > _edgeWidth) {
      _primary = null;
      _active[e.pointer] = e.timeStamp;
      return;
    }
    if (_active.isEmpty) {
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
    }
    _active[e.pointer] = e.timeStamp;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _primary) return;
    _moves++;
    _last = e.position;
    _sampleGesture();
    if (_moves == 1) _firstMoveMs = _ms(e);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: (e) => _onEnd(e, cancelled: false),
    onPointerCancel: (e) => _onEnd(e, cancelled: true),
    child: widget.child,
  );
}
