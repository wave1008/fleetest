// scenarioReports.ts
// シナリオ実行レポート(Markdown、CLI が書く)の探索。vscode 非依存(lastResults.ts と同じ理由)。
// ファイル名規則は Swift 側のレポート書き出しコードとの契約:
//   scenario-<YYYYMMDD>-<HHMMSS>-<mmm>-<reportSlug(シナリオID)>.md
//   reportSlug は Swift の ScenarioReportWriter.slug と同じ規則(記号は _・長さは UTF-8 のバイトで切り、S 番号は残す)。
//   両側の表(ReportSlugContractTests.swift / scenarioReports.test.mjs)を同じにする
// タイムスタンプ部は辞書順 = 時刻順なので、「最新」はファイル名の文字列最大値で求まる。

import fs from "node:fs";
import path from "node:path";

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** ScenarioReportWriter.slugByteBudget と同じ値(最も長い画像のファイル名が NAME_MAX 255 バイトに収まる上限) */
const SLUG_BYTE_BUDGET = 96;
const KEEP = /[\p{L}\p{M}\p{N}\u3040-\u30FF]/u;

function sanitizedSlug(text: string): string {
  let out = "";
  for (const cp of text) out += KEEP.test(cp) ? cp : "_";
  while (out.includes("__")) out = out.replace(/__/g, "_");
  return out.replace(/^_+|_+$/g, "");
}

function byteTruncated(text: string, budget: number): string {
  let out = "";
  for (const { segment } of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)) {
    if (Buffer.byteLength(out + segment, "utf8") > budget) break;
    out += segment;
  }
  return out.replace(/^_+|_+$/g, "");
}

/** レポートのファイル名に入るシナリオ ID の形(Swift の ScenarioReportWriter.slug と同じ) */
export function reportSlug(id: string): string {
  const dot = id.lastIndexOf(".");
  if (dot > 0) {
    const head = sanitizedSlug(id.slice(0, dot));
    const tail = sanitizedSlug(id.slice(dot + 1));
    if (head && tail) {
      const whole = `${head}_${tail}`;
      if (Buffer.byteLength(whole, "utf8") <= SLUG_BYTE_BUDGET) return whole;
      const headBudget = SLUG_BYTE_BUDGET - Buffer.byteLength(tail, "utf8") - 1;
      if (headBudget > 0) return `${byteTruncated(head, headBudget)}_${tail}`;
    }
  }
  const whole = sanitizedSlug(id);
  return whole ? byteTruncated(whole, SLUG_BYTE_BUDGET) : "scenario";
}

function reportFileNameRegex(scenarioId: string): RegExp {
  const expectedSuffix = reportSlug(scenarioId.normalize("NFC"));
  return new RegExp(`^scenario-\\d{8}-\\d{6}-\\d{3}-${escapeRegExp(expectedSuffix)}\\.md$`);
}

export function reportsDir(workspaceRoot: string, project: string): string {
  return path.join(workspaceRoot, "TestProjects", project, "reports");
}

/** dir 内で scenarioId に一致する最新レポートの絶対パス。ディレクトリ無し/読み取り不可/該当無しは undefined。
 * readdirSync は macOS だと日本語ファイル名を NFD で返すことがある(lastResults.ts lookupKey と同じ罠)ので
 * 照合前に NFC 正規化する。 */
export function findLatestReport(dir: string, scenarioId: string): string | undefined {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return undefined;
  }
  const regex = reportFileNameRegex(scenarioId);
  let latest: string | undefined;
  for (const name of names) {
    const normalized = name.normalize("NFC");
    if (regex.test(normalized) && (latest === undefined || normalized > latest)) {
      latest = normalized;
    }
  }
  return latest === undefined ? undefined : path.join(dir, latest);
}

export interface RecentReport {
  scenarioId: string;
  path: string;
  fileName: string;
}

/** scenarioIds 各々の最新レポートを、ファイル名(=タイムスタンプ)降順で返す(見つからないものは除外)。 */
export function listRecentReports(dir: string, scenarioIds: Set<string>): RecentReport[] {
  const result: RecentReport[] = [];
  for (const scenarioId of scenarioIds) {
    const reportPath = findLatestReport(dir, scenarioId);
    if (reportPath) {
      result.push({ scenarioId, path: reportPath, fileName: path.basename(reportPath) });
    }
  }
  return result.sort((a, b) => (a.fileName < b.fileName ? 1 : a.fileName > b.fileName ? -1 : 0));
}
