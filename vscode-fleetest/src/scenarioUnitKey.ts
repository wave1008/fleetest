// 実行の単位(シナリオ ID × バリアント)の鍵と表示名。vscode 非依存・i18n 非依存
// (拡張と webview の両バンドルに入る)。鍵の文字列は Swift の ScenarioUnitKey.description と同じ
// (`ID` / `ID@variant`。`@` はシナリオ ID に現れない)。バリアント無しの run は常に ID のまま。

export function scenarioUnitKey(scenario: string, variant?: string | null): string {
  return variant ? `${scenario}@${variant}` : scenario;
}

/** 画面に出すシナリオ名。バリアントがあるときだけ `ID [variant]`。 */
export function scenarioUnitLabel(scenario: string, variant?: string | null): string {
  return variant ? `${scenario} [${variant}]` : scenario;
}

/** Test Explorer の失敗メッセージ。variant があるときだけ `[variant] ` を先頭へ付ける(無い run は本文のまま)。 */
export function failureMessageText(text: string, variant?: string | null): string {
  return variant ? `[${variant}] ${text}` : text;
}
