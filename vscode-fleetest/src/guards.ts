/** vscode 非依存の小さな型ガード。拡張・webview 両バンドルから import してよい(import を足さないこと)。 */

/** 配列も true(JSON の object 判定。配列を除きたい呼び手は自前で `!Array.isArray` を足す)。 */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
