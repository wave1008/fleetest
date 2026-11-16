// Test Explorer の TestItem.description に付ける「自己修復で成功」の印の付け外し(runHandler.ts が呼ぶ)。
// description は testTree.ts も使う(削除中・下書き)ので、**自分が付けた印だけ**を外し、他の表示は上書きしない。

import { laneStrings, tLane } from "./i18n/strings/lane";

/** シナリオの開始時。印なら外す(付けた後に言語が変わっても外れるよう日英どちらとも照合)。それ以外はそのまま */
export function descriptionOnStarted(current: string | undefined): string | undefined {
  const mark = laneStrings["lane.healedDescription"];
  return current === mark.ja || current === mark.en ? undefined : current;
}

/** 成功時。自己修復したステップがあり、他の表示が無いときだけ印を付ける */
export function descriptionOnPassed(current: string | undefined, healedSteps: number): string | undefined {
  return healedSteps > 0 && !current ? tLane("lane.healedDescription") : current;
}
