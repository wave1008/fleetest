// 要求 id を持たない応答(deviceCatalog / installedDevices。型は変えられない)を、要求と対応付けるための直列化。
// 閉じたダイアログの要求が飛んでいる間は次の要求を撃たずに控え、先に届く1通は「古い」として捨てる。
// 要求が1本ずつしか飛ばないので、届いた応答は必ず直近に撃った要求のもの(順序の入れ替わりが起きない)。
// ホストは要求ごとに必ず1通返す前提(ok:false を含む。応答が来ないと次の要求は撃たれないまま)。

// 応答の期限。ホスト側の子に期限の無い経路(CoreSimulator のハング等)で応答が永久に来ないと、
// 開き直すたびに控えへ積むだけで二度と撃てなくなる。期限はホスト側の runTagged の kill タイマー
// (monitorPanel.ts の 120s)と同じ値 —— 子が殺されて応答が来るか、来ないままかの分かれ目
export const GATE_EXPIRY_MS = 120_000;

export function createRequestGate() {
  return { outstanding: false, stale: false, queued: null, sentAt: 0 };
}

/** 要求を撃つ。前の要求が飛んでいれば控え、その応答(捨てられる)の後で撃つ。
 *  期限を跨いだ要求は来ないものとみなして新しい要求を撃つ(期限後に古い応答が届いた場合は
 *  同種のカタログなので誤って描いても害が小さく、新しい応答が直後に上書きする)。 */
export function gateSend(gate, send, now = Date.now()) {
  if (gate.outstanding && now - gate.sentAt < GATE_EXPIRY_MS) {
    gate.queued = send;
    return;
  }
  gate.outstanding = true;
  gate.stale = false;
  gate.queued = null;
  gate.sentAt = now;
  send();
}

/** ダイアログを閉じた。飛んでいる要求は古くなり、控えは捨てる。 */
export function gateClose(gate) {
  if (gate.outstanding) {
    gate.stale = true;
  }
  gate.queued = null;
}

/** 応答が届いた。true = 今のダイアログのものなので描いてよい / false = 古いので捨てる。 */
export function gateReceive(gate) {
  const wasStale = gate.stale;
  gate.outstanding = false;
  gate.stale = false;
  const queued = gate.queued;
  gate.queued = null;
  if (queued) {
    gateSend(gate, queued);
  }
  return !wasStale;
}
