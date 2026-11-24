// 要求 id を持たない応答(deviceCatalog / installedDevices。型は変えられない)を、要求と対応付けるための直列化。
// 閉じたダイアログの要求が飛んでいる間は次の要求を撃たずに控え、先に届く1通は「古い」として捨てる。
// 要求が1本ずつしか飛ばないので、届いた応答は必ず直近に撃った要求のもの(順序の入れ替わりが起きない)。
// ホストは要求ごとに必ず1通返す前提(ok:false を含む。応答が来ないと次の要求は撃たれないまま)。

export function createRequestGate() {
  return { outstanding: false, stale: false, queued: null };
}

/** 要求を撃つ。前の要求が飛んでいれば控え、その応答(捨てられる)の後で撃つ。 */
export function gateSend(gate, send) {
  if (gate.outstanding) {
    gate.queued = send;
    return;
  }
  gate.outstanding = true;
  gate.stale = false;
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
