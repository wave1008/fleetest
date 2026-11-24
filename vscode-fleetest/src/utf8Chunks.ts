// utf8Chunks.ts
// 子プロセスの Buffer チャンクを UTF-8 として読む共有の補助。vscode モジュールに依存しない。
//
// チャンクごとの `chunk.toString("utf8")` は、マルチバイト文字がチャンク境界で分断されると U+FFFD に化ける
// (64KB を超える JSON・日本語や絵文字を含む出力で起きる)。どちらも Buffer のまま持ち、
// 文字列化は「全部届いた後」「改行バイト(0x0A)で1行が確定した後」にだけ行う(ndjson.ts と同じ規律)。

const LF = 0x0a;

/** 全チャンクを Buffer のまま集め、text() で1回だけ文字列化する(JSON 全体を読む口・出力全体の保持用)。 */
export class Utf8Text {
  private readonly chunks: Buffer[] = [];

  push(chunk: Buffer): void {
    this.chunks.push(chunk);
  }

  text(): string {
    return Buffer.concat(this.chunks).toString("utf8");
  }
}

/** チャンクから、改行で確定した行(末尾の改行・CR を除く)を取り出す。未完の末尾行は持ち越し、rest() で取る。 */
export class Utf8LineSplitter {
  private pending: Buffer = Buffer.alloc(0);

  /** 今回のチャンクで確定した行(空行も含む。trim・空行除外は呼び手) */
  push(chunk: Buffer): string[] {
    this.pending = this.pending.length === 0 ? chunk : Buffer.concat([this.pending, chunk]);
    const lines: string[] = [];
    let at = this.pending.indexOf(LF);
    while (at !== -1) {
      lines.push(this.pending.subarray(0, at).toString("utf8").replace(/\r$/, ""));
      this.pending = this.pending.subarray(at + 1);
      at = this.pending.indexOf(LF);
    }
    return lines;
  }

  /** 改行の無いまま終わった末尾(close で flush する)。呼ぶと持ち越しは空になる */
  rest(): string {
    const text = this.pending.toString("utf8").replace(/\r$/, "");
    this.pending = Buffer.alloc(0);
    return text;
  }
}
