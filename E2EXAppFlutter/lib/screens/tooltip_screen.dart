import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class TooltipScreen extends StatefulWidget {
  const TooltipScreen({super.key});

  @override
  State<TooltipScreen> createState() => _TooltipScreenState();
}

// Flutter の Tooltip は表示継続時間を明示できる(showDuration)が、非表示になった瞬間を
// 通知する public API が無い(Compose の tooltipState.isVisible に相当するものが無い)。
// 長押しで出たツールチップは**指を離してから** showDuration で消えるので、出た押しの離しから
// 同じ長さだけ待って hidden に倒す近似値で txt_tooltip_state を出す(実際の非表示タイミングの
// 直接観測ではない。docs/ui-contract.md に明記)。**出たときから数えない** —— 押している間に
// 2 秒を過ぎると文言は見えたまま hidden に倒れた(OI-230。陽性対照で観測)。
const _showDuration = Duration(seconds: 2);

class _TooltipScreenState extends State<TooltipScreen> {
  String _state = 'hidden';

  // OI-230 の測る口(E2EX-Flutter だけ)。s = 画面を開いてからの押し始め(ms)、他は押し始めからの ms。
  // docs は E2EXAppCMP/docs/ui-contract.md のツールチップ。シナリオは検証しない。
  // **文字を変えるのはツールチップが出た押しだけ**(出なかった押しで変えると、木の比較・画素の指紋で
  // 「画面が変わらなかった」を見る判定がこの画面で働かない)。押し・離しの時刻は控えに置き、出たときに載せる。
  final _clock = Stopwatch()..start();
  int? _s, _w, _r, _u, _h;
  int? _pressAt, _releaseAt;
  // 押している指の id。押しは 空 → 1本目 で始まり、空に戻った時点で離したとみなす(2本目の指の離しで押しを終えない)
  final _pointers = <int>{};
  int _generation = 0; // 前の押しの hidden の時計が次の押しの状態・h を書かないように

  int _now() => _clock.elapsedMilliseconds;
  int _rel(int t) => t - _s!;
  String _ms(int? t) => t == null || _s == null ? '-' : '${_rel(t)}';
  String get _trace => _s == null
      ? 'trace=-'
      : 'trace=s$_s w${_ms(_w)} r${_ms(_r)} u${_ms(_u)} h${_ms(_h)}';

  void _released(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isNotEmpty) return;
    _releaseAt = _now();
    // 出た押しの離しだけ載せる(画面はツールチップで既に変わっている)
    if (_s != null && _s == _pressAt) {
      setState(() => _u = _releaseAt);
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    final generation = _generation;
    Future.delayed(_showDuration, () {
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = 'hidden';
        _h = _now();
      });
    });
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ツールチップ',
        body: ScreenColumn(children: [
          TaggedText(Tags.tooltipState, 'tooltip=$_state'),
          // Tooltip の吹き出し本文(#txt_tooltip 相当)には id を付けられない
          // (message/richMessage はカスタム Widget を差し込めない Flutter の制約)。
          // ラベルで指す前提(docs/ui-contract.md)。
          Tooltip(
            message: 'これはツールチップです',
            triggerMode: TooltipTriggerMode.longPress,
            showDuration: _showDuration,
            // アンカーの意味付けは #btn_tooltip_anchor 側の label('情報')に一本化する
            // (Tooltip 自身の message を semantics へ二重に出さない)。
            excludeFromSemantics: true,
            onTriggered: () {
              ++_generation; // 前の押しの hidden の時計を無効にする
              final triggeredAt = _now();
              setState(() {
                _s = _pressAt;
                _w = triggeredAt;
                _u = _releaseAt;
                _h = null;
                _state = 'shown';
                _r = _now();
              });
              // 押している指がこの Listener に無い(出る前に離した・この Listener を通らない押しや読み上げの操作で出た)なら、
              // 離しを待たずにここから数える(待つと hidden に戻らない)
              if (_pointers.isEmpty) _scheduleHide();
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                if (_pointers.isEmpty) {
                  _pressAt = _now();
                  _releaseAt = null;
                }
                _pointers.add(e.pointer);
              },
              onPointerUp: (e) => _released(e.pointer),
              onPointerCancel: (e) => _released(e.pointer),
              child: tagged(
                Tags.btnTooltipAnchor,
                IconButton(icon: const Icon(Icons.info_outline), onPressed: () {}),
                button: true,
                label: '情報',
              ),
            ),
          ),
          TaggedText(Tags.tooltipTrace, _trace),
        ]),
      );
}
