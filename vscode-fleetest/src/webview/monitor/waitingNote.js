// 「デバイスを待機しています」(#empty)をラインビューが非表示のときだけ下のペイン(#lanes-waiting)にも出す。
// 状態の書き手は3つ: 待機の有無 = deviceTiles.js / main.js(#empty を出し入れする箇所)、
// ラインビューの表示・グリッドビューの開閉 = splitter.js。循環 import を作らないよう、
// どれもこのモジュールだけを呼ぶ。
// **#lanes-waiting は inline の display で出し入れする**(CSS の畳み規則はここに勝てない)ので、
// グリッドビューを畳んだかどうかもこの1箇所で解く。

import { emptyMessage, lanesWaiting } from './domRefs.js';
import { t } from '../i18n.js';

let waiting = false;
let lineViewHidden = false;
let gridViewHidden = false;
// 待機の文言は静的 HTML(monitorHtml.ts)が描く。保持中に差し替えて、解除で戻すため控える
const waitingText = emptyMessage.textContent;

/** `fleetest monitor pause` の保持中か(供給元はホストの monitorHold メッセージ)。文言だけを差し替える。 */
export function setMonitorHeld(value) {
  const text = value ? t('wvMonitor2.waiting.held') : waitingText;
  emptyMessage.textContent = text;
  lanesWaiting.textContent = text;
}

function render() {
  const shown = waiting && lineViewHidden && !gridViewHidden;
  lanesWaiting.style.display = shown ? 'flex' : 'none';
  // 同じ場所に重ねる「デバイスを選択して下さい」(#preview-empty)を隠す合図。デバイスがまだ来ていない間は
  // 選べるものが無いので、待機の案内だけを出す(両方出すと文字が重なる)
  lanesWaiting.closest('#panel-devices')?.classList.toggle('lanes-waiting-shown', shown);
}

export function setDevicesWaiting(value) {
  waiting = value;
  emptyMessage.style.display = value ? 'flex' : 'none';
  render();
}

export function setLineViewHiddenForWaiting(value) {
  lineViewHidden = value;
  render();
}

export function setGridViewHiddenForWaiting(value) {
  gridViewHidden = value;
  render();
}
