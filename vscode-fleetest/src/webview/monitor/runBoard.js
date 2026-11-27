// run ボード(フリート横断の実行状況。DS-18)。ツールバー直下・ラインビューの上に
// 常設(main.js の 'monitorRuns'/'runBoardReset'/'runBoardCollapsed'/'hostMetricsMachines' ケースが
// このモジュールへ渡す。契約: monitorWebviewMessages.ts の同名メッセージ)。
//
// 状態の畳み込みは runBoardModel.ts(vscode 非依存・machineLockModel.ts と同じ立場)に委ね、
// ここは DOM の生成・更新と文言(t())だけを持つ。**経過秒の秒読みは自分の時計で1秒ごとに
// 数字だけ書き換える**(DOM は作り直さない。CLAUDE.md の規律)。

import { t } from '../i18n.js';
import {
  runBoard, runBoardHeader, runBoardToggle, runBoardTitle, runBoardTachometer, runBoardTachometerToggle, runBoardExpandAll, runBoardRows, runBoardSplit,
} from './domRefs.js';
import { vscode, persistedState } from './vscodeApi.js';
import {
  paintMachineBadge, isMachineDisabled, onMachineEnablementChanged, settingsMachineOrder,
  LOCAL_MACHINE_LABEL,
} from './machineColors.js';
import { compareMachineOrder } from '../../monitorDeviceModel';
import { scenarioUnitLabel } from '../../scenarioUnitKey';
import { setHoverTip } from './hoverTip.js';
import {
  deviceIdForLane, selectOnlyDevices, devicesOnMachine, setRunningDevices,
  isPlatformVisible, onPlatformFilterChanged, setJobActive,
} from './deviceTiles.js';
import { reapplyPaneHeights } from './splitter.js';
import { HM_MAX_SAMPLES, onHostMetricsCommitted } from './hostCharts.js';
import {
  LOCAL_MACHINE_KEY,
  applyMonitorRunsEvent,
  buildRunGroups,
  listJobs,
  jobCounts,
  jobsMayBeRunning,
  jobRunKind,
  jobKey,
  machinesWithoutRuns,
  liveElapsedSeconds,
  currentSupplyStep,
  machineServicesNotes,
} from '../../runBoardModel';
import {
  ACTIONS_PER_SECOND_PER_SEGMENT, ActionTachometer, easeToward, segmentLevel, segmentCount, METER_SEGMENTS, segmentTier, trendTierStops, valueTier,
} from '../../actionTachometerModel';

// run ボードの ❄️ ○ T(RunBoardRun の欄名・絵文字・説明。説明の文言はタイルと同じ)
const RUN_DEVICE_STATES = [
  ['frozenDevices', 'wvMonitor.tile.frozen', 'wvMonitor.tile.frozenTitle'],
  ['blankDevices', 'wvMonitor.tile.blank', 'wvMonitor.tile.blankTitle'],
  ['textlessDevices', 'wvMonitor.tile.textless', 'wvMonitor.tile.textlessTitle'],
];

let runsByMachine = new Map();
// 見出し行のタコメーター表示切替(既定 ON。値は monitorPanel.ts の showTachometer メッセージで届く)。
// OFF でも数え続ける(ON に戻したとき数値とチャートが途切れない)。**モジュール冒頭に置く** —— 末尾の初回 render() が読む
let showTachometer = true;
// 動きを減らす設定(バーの慣性とタコメーターのフェードを切る)。**モジュール冒頭に置く** —— 初回 render() が読む
const reduceMotion = typeof window.matchMedia === 'function'
  && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
// ヘッダの機械要約に出すリモート機の一覧(手元は含まない)。'hostMetricsMachines' に相乗りする
// (専用のホスト配線を増やさない —— 対象は「直近の monitorDevices に居る機械」で run ボードが
// 知りたい「フリートに居る機械」と同じ集合)。
let remoteMachines = [];

// ボード全体の開閉。host 復元前の既定は展開(webview 側 splitter.js の isFleetVisible と同じ規律)。
let collapsed = false;
// 「全て展開」トグル。**モードであって一度きりの操作ではない** —— ON の間は、あとから現れた
// run も展開された状態で出る(ユーザー決定)。host が workspaceState に持つ。
let expandAll = false;
// 機械の行の開閉を利用者が変えたもの(**機械の鍵** → 開いているか)。**既定はどの行も閉じ**
// (ユーザー決定)—— expandAll が OFF の間、行は利用者が開かない限り開かない。
// **行の鍵(rowKey)で引かない** —— 行の鍵は run の pid と「run の有無」を含むので、次の run・
// 空き⇔実行中 の切り替わりで変わり、記録を失った行が勝手に開閉する。
// host 側には永続化しない(webview の getState だけ = パネルの寿命)。
const machineExpansion = new Map(
  persistedState.runBoardMachineExpansion && typeof persistedState.runBoardMachineExpansion === 'object'
    ? Object.entries(persistedState.runBoardMachineExpansion).filter(([, v]) => typeof v === 'boolean')
    : [],
);

// 行の鍵。**1行 = 1機械**(ユーザー決定)—— run のある機械は run ごとに1行
// (機械分担の run は機械の数だけ行になる)、run の無い機械は1行。
// **run の行は機械 + pid で引く(groupKey を使わない)** —— 準備中・ビルド中の控えは runID/runGroup が
// nil で、走り出すと同じ pid の控えが runID 入りに上書きされる。groupKey で引くと走り出した瞬間に
// 行の DOM が作り直される。**開閉の記録はこの鍵では引かない**(machineExpansion)
function runRowKey(run) {
  return 'run\u0000' + (run.machine ?? '') + '\u0000' + run.pid;
}
function idleRowKey(machine) {
  return 'idle\u0000' + machine;
}

// 行の DOM とブックキーピング。render() が行の集合に合わせて足し引きする。
const rows = new Map();

/** 開閉の記録の鍵(machineList() の綴り = '' が手元)。同じ機械の run の行と空きの行が共有する。 */
function expansionKey(row) {
  return row.run ? (row.run.machine ?? LOCAL_MACHINE_KEY) : row.idle.machine;
}

/** その行を開くか。**expandAll が ON なら個別の記録によらず開く**(新しい行も含む)。 */
function isRowExpanded(row) {
  return expandAll || machineExpansion.get(expansionKey(row)) === true;
}

function persistMachineExpansion() {
  vscode.setState(Object.assign({}, vscode.getState(), {
    runBoardMachineExpansion: Object.fromEntries(machineExpansion),
  }));
}

function formatMinSec(seconds) {
  const safe = Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
  const m = Math.floor(safe / 60);
  const s = Math.floor(safe % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

function machineLabel(machine) {
  return machine === LOCAL_MACHINE_KEY || machine === undefined ? LOCAL_MACHINE_LABEL : machine;
}

// machineList() の鍵('' = 手元)を MonitorDevice / monitorRuns の規約(undefined = 手元)へ。
function machineKey(machine) {
  return machine === LOCAL_MACHINE_KEY ? undefined : machine;
}

function machineList() {
  // **「マシン有効」が off の機械は出さない**(ユーザー決定)—— ディスパッチの対象外
  // なので、「空き」と並べると使える機械に見える。isMachineDisabled は '' を手元として読む
  // (LOCAL_MACHINE_KEY と同じ綴り)。**run はこれで消えない** —— 一覧に無い機械の run は
  // render の最後の loop が拾う(走っている事実は隠さない)
  const order = settingsMachineOrder();
  const remotes = [...remoteMachines].sort((a, b) => compareMachineOrder(a, b, order));
  return [LOCAL_MACHINE_KEY, ...remotes].filter((machine) => !isMachineDisabled(machine));
}

// 「マシン有効」の切り替えと並べ替えは remoteConfig で届く(machineColors.js)。届いた時点で並べ直す
// (この通知は remoteConfig のたびに鳴るので、並べ替えの通知 onMachineOrderChanged を別に足さない = 二重に描く)
onMachineEnablementChanged(() => render());

function applyCollapsedUi() {
  runBoard.dataset.collapsed = collapsed ? 'true' : 'false';
  // 行の chevron と同じ規律 —— 文字は常に ▶ で、向きは CSS の回転で表す
  runBoardToggle.textContent = '▶';
  runBoardToggle.dataset.expanded = collapsed ? 'false' : 'true';
  runBoardToggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
  const label = t(collapsed ? 'runBoard.expand' : 'runBoard.collapse');
  runBoardToggle.title = label;
  runBoardToggle.setAttribute('aria-label', label);
  // **畳みは自分で伝える** —— ドラッグで高さを書いてあると箱の大きさが変わらず、splitter.js の
  // ResizeObserver が鳴かない(畳んだのに行の無い高い帯が残る)
  reapplyPaneHeights();
}

// **ヘッダ行のどこを押しても開閉する**(三角だけが当たり判定だと小さすぎる。ユーザー指摘)。
// トグルは <button> なのでキーボードの Enter/Space も click になり、そのままここへ来る
runBoardHeader.addEventListener('click', () => {
  collapsed = !collapsed;
  applyCollapsedUi();
  render();
  vscode.postMessage({ type: 'setRunBoardCollapsed', value: collapsed });
});

/** host からの復元値(sendInitialState)。ユーザー操作の再送はしない(setFleetVisible と同じ規律)。 */
export function setRunBoardCollapsed(value) {
  if (typeof value !== 'boolean') {
    return;
  }
  collapsed = value;
  applyCollapsedUi();
}

// 表示フィルタの切り替えでもツリーを描き直す(deviceTiles.js が入口で落とした一覧を読むので、
// 呼ばないと隠したはずのデバイスが次の監視サイクルまで残る)
onPlatformFilterChanged(() => render());

// ---- 2カラムの境目(ユーザー決定) ----
// **px で持つ**(比率ではない) —— ドラッグは px で来るので、比率にすると丸めのたびに境目が滑る。
// null = まだドラッグされていない = 既定(いちばん長いラベルの幅)を毎回引き直す。
// **どこにも保存しない**(ユーザー決定)—— 寿命はこのパネルそのもの。タブを閉じたら
// 解放し、開き直したら既定へ戻す。**この変数だけが持ち主**なので、host へ送る・getState へ書く
// のどちらも足さない(どちらも閉じても残り、リセットされなくなる)。
// 隠す/再表示は retainContextWhenHidden で webview が生き続けるため、幅も保たれる。
let desiredSplit = null;

// 左右それぞれに最低これだけは残す(境目を端まで引き切って片方を潰さない)。
const MIN_COLUMN_WIDTH = 80;
// 既定は**いちばん長いラベルがちょうど収まる幅 + DEFAULT_SPLIT_EXTRA**(ユーザー決定)。
// 比率ではないので、機械名・デバイス名の長さで決まる。ドラッグするまでは毎回引き直す
// (デバイスが増えて名前が伸びたら追従する)。
function naturalLeftWidth() {
  // 測る間だけ左カラムを中身なりの幅にする(flex-basis が効いたままだと今の幅しか返らない)
  runBoardRows.classList.add('run-board-measuring');
  let width = 0;
  for (const el of runBoardRows.querySelectorAll('.run-board-col-left')) {
    // **offsetWidth ではなく矩形の実寸で測る** —— offsetWidth は整数へ丸めた値なので、
    // 中身が 422.4px のときに 422 を返し、0.4px 足りずにその行だけ "…" になる
    // (実地で踏んだ: 同じ長さの行が1つだけ切れた)。ceil は最後に1回だけ
    width = Math.max(width, el.getBoundingClientRect().width);
  }
  runBoardRows.classList.remove('run-board-measuring');
  return Math.ceil(width);
}
// マシン名の列の幅 = いちばん長いマシン名バッジの幅(ユーザー決定)。プロジェクト / 実行プロファイルの
// 書き出しを全行で揃えるため。測り方は naturalLeftWidth と同じ(矩形の実寸・最後に切り上げ)
function machineColumnWidth() {
  let width = 0;
  for (const el of runBoardRows.querySelectorAll('.run-board-machine-badge')) {
    width = Math.max(width, el.getBoundingClientRect().width);
  }
  return Math.ceil(width);
}
// 既定の幅(ドラッグ前)に足す余白(px。ユーザー決定)。ラベルがちょうど収まる幅では
// 左カラムが詰まって見えるため。右カラムの 80px は clampSplit が別に守る
const DEFAULT_SPLIT_EXTRA = 100;
// 行の左右の padding(style.css の .run-board-row-summary / .run-board-lane と同じ値)。
// **片方だけ変えない** —— 境目の x は 8px + --rb-left で描くので、ここがずれると線と列が割れる。
const ROW_PADDING_X = 8;

function splitContentWidth() {
  return runBoardRows.clientWidth - ROW_PADDING_X * 2;
}

function clampSplit(width, content) {
  return Math.min(Math.max(width, MIN_COLUMN_WIDTH), Math.max(MIN_COLUMN_WIDTH, content - MIN_COLUMN_WIDTH));
}

function renderSplit() {
  const content = splitContentWidth();
  if (content <= 0) {
    return;   // 「デバイスモニター」タブが非表示の間は測れない(splitter.js の panelHidden と同じ規律)
  }
  // マシン名の列は**左カラムを測る前に**決める(列の幅が左カラムの中身なりの幅に入る)
  runBoard.style.setProperty('--rb-machine', machineColumnWidth() + 'px');
  const left = clampSplit(desiredSplit ?? naturalLeftWidth() + DEFAULT_SPLIT_EXTRA, content);
  runBoard.style.setProperty('--rb-left', left + 'px');
  // 境目は見出し行には掛けない(掴む相手ではないうえ、チェックボックスに重なる)
  runBoard.style.setProperty('--rb-head', runBoardHeader.offsetHeight + 'px');
}

let splitPointerId = null;

runBoardSplit.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) {
    return;
  }
  splitPointerId = event.pointerId;
  runBoardSplit.setPointerCapture(event.pointerId);
  runBoardSplit.classList.add('dragging');
  event.preventDefault();
  event.stopPropagation();
});
runBoardSplit.addEventListener('pointermove', (event) => {
  if (splitPointerId !== event.pointerId) {
    return;
  }
  const content = splitContentWidth();
  if (content <= 0) {
    return;
  }
  // 掴んだ位置ではなく**ポインタの x そのもの**で決める(境目は 7px の当たりに対し線は1px なので、
  // 差分で動かすと掴んだ場所ぶんずれたまま追従する)
  desiredSplit = clampSplit(
    Math.round(event.clientX - runBoardRows.getBoundingClientRect().left - ROW_PADDING_X),
    content,
  );
  renderSplit();
});
const endSplitDrag = (event) => {
  if (splitPointerId !== event.pointerId) {
    return;
  }
  splitPointerId = null;
  runBoardSplit.classList.remove('dragging');
  runBoardSplit.releasePointerCapture(event.pointerId);
};
runBoardSplit.addEventListener('pointerup', endSplitDrag);
runBoardSplit.addEventListener('pointercancel', endSplitDrag);
// **見出し行の開閉へ波及させない**(境目は run ボードの中に居る)
runBoardSplit.addEventListener('click', (event) => event.stopPropagation());
window.addEventListener('resize', () => renderSplit());

/** デバイスの一覧・モニターの範囲(project/profile)が変わったら main.js から呼ぶ。
 * **run ボードは monitorRuns でしか描き直さない**ので、これが無いとツリーのデバイスが古いまま残る。 */
export function refreshRunBoardDevices() {
  render();
}

/** hostMetricsMachines 受信のたびに main.js から呼ぶ(専用のホスト配線を増やさない。上のコメント参照)。 */
export function setRunBoardMachines(machines) {
  remoteMachines = Array.isArray(machines) ? machines.filter((m) => typeof m === 'string' && m !== '') : [];
  render();
}

// run の開始・終了(と見出し行のボタン)でタコメーターをフェードで出し入れする(ユーザー決定)。
// 消すときは透明になってから display:none(見出し行の並びが詰まるのはフェードの後)。出すときは表示してから不透明へ。
// 最初の1回(パネルを開いた直後)と動きを減らす設定では即座に切り替える
const TACHO_FADE_MS = 400; // 見た目の時間(ms)。CSS の transition もここから書く
let tachoVisible; // undefined = まだ1度も決めていない
let tachoFadeTimer;

function setTachometerVisible(visible) {
  if (visible === tachoVisible) { return; }
  const first = tachoVisible === undefined;
  tachoVisible = visible;
  clearTimeout(tachoFadeTimer);
  const animate = !first && !reduceMotion;
  runBoardTachometer.style.transition = animate ? `opacity ${TACHO_FADE_MS}ms ease` : '';
  if (visible) {
    runBoardTachometer.style.display = '';
    if (animate) { void runBoardTachometer.offsetWidth; } // 透明の状態を一度描かせてから外す = 遷移が走る
    runBoardTachometer.classList.remove('tacho-hidden');
  } else {
    runBoardTachometer.classList.add('tacho-hidden');
    if (animate) {
      tachoFadeTimer = setTimeout(() => { runBoardTachometer.style.display = 'none'; }, TACHO_FADE_MS);
    } else {
      runBoardTachometer.style.display = 'none';
    }
  }
}

// run が終わっても TACHO_HOLD_AFTER_RUN_MS は出したまま(ユーザー決定)。その間に次の run が始まれば隠さない
// (周の切れ目でちらつかない)。ボタンで OFF にしたときは利用者の操作なので待たない
const TACHO_HOLD_AFTER_RUN_MS = 10_000;
let tachoHoldTimer;

/** activeCount = 走っている run の数 + 続いているジョブの数 */
function updateTachometerVisibility(activeCount) {
  if (!showTachometer || activeCount > 0) {
    clearTimeout(tachoHoldTimer);
    tachoHoldTimer = undefined;
    setTachometerVisible(showTachometer);
    return;
  }
  if (tachoVisible !== true) {
    setTachometerVisible(false); // 出していない(パネルを開いた時点で run が無い等)なら待たない
    return;
  }
  tachoHoldTimer ??= setTimeout(() => {
    tachoHoldTimer = undefined;
    setTachometerVisible(false);
  }, TACHO_HOLD_AFTER_RUN_MS);
}

function renderHeader(groups, jobCount) {
  runBoardTitle.textContent = t('runBoard.title');
  // タコメーターは run が実行中(run が1本以上。準備中も含む)のときだけ出す(ユーザー決定)。
  // **ジョブが続いている間は run が 0 本でも隠さない**(ユーザー決定)—— run と run のあいだ(次の SUT のビルド中等)に
  // 隠すと、右のジョブの数が左へ寄り、次の run で元の位置へ戻る動きになる。
  // hidden 属性は .run-board-tachometer の display に負けるので style で切る。隠している間も数え続ける
  updateTachometerVisibility(groups.length + jobCount);
  // **折りたたみ中は出さない**(本体が見えないので押しても何も起きない)。run 0 本でも出す ——
  // これはモードのスイッチで、「いま開く行があるか」とは別
  runBoardExpandAll.style.display = collapsed ? 'none' : '';
  // ON の見せ方は「デバイスをすべて選択」と同じ .toggled(ユーザー決定)
  runBoardExpandAll.classList.toggle('toggled', expandAll);
  runBoardExpandAll.setAttribute('aria-pressed', expandAll ? 'true' : 'false');
  // アイコンだけなので(ユーザー決定)、名前は tooltip と aria-label が持つ。
  // 出し方は「デバイスをすべて選択」と同じ(deviceTiles.js の renderSelectAllButton)。
  // ネイティブ title は使わない(表示まで約1秒で指定できない。setHoverTip が title を空にするので
  // 二重にも出ない)。**文言は ON/OFF で入れ替えない**(ユーザー決定)
  const expandAllLabel = t('runBoard.expandAll');
  setHoverTip(runBoardExpandAll, expandAllLabel);
  runBoardExpandAll.setAttribute('aria-label', expandAllLabel);
  // タコメーターの表示切替。run 0 本・畳み中でも出す(モードのスイッチ。見せ方は「全て展開」と同じ .toggled)
  runBoardTachometerToggle.classList.toggle('toggled', showTachometer);
  runBoardTachometerToggle.setAttribute('aria-pressed', showTachometer ? 'true' : 'false');
  const tachometerToggleLabel = t('runBoard.toggleTachometer');
  setHoverTip(runBoardTachometerToggle, tachometerToggleLabel);
  runBoardTachometerToggle.setAttribute('aria-label', tachometerToggleLabel);
}

function setExpandAll(value) {
  expandAll = value;
  vscode.postMessage({ type: 'setRunBoardExpandAll', value });
}

// 押したらその場で切り替え、拡張へ保存を頼む(拡張は同じ値を showTachometer で返す)。ヘッダ行の開閉へ波及させない
runBoardTachometerToggle.addEventListener('click', (event) => {
  event.stopPropagation();
  showTachometer = !showTachometer;
  vscode.postMessage({ type: 'setShowTachometer', value: showTachometer });
  render();
});

// **ヘッダ行の開閉へ波及させない** —— 親(run-board-header)が click で開閉するので、
// stopPropagation を外すとボタンを押した瞬間にボードごと畳まれる
runBoardExpandAll.addEventListener('click', (event) => {
  event.stopPropagation();
  if (expandAll) {
    // OFF にしたら個別の記録も捨てて既定へ戻す(残すと OFF にしたのに全部開いたままになる)
    machineExpansion.clear();
    persistMachineExpansion();
  }
  setExpandAll(!expandAll);
  render();
});

/** host からの復元値(sendInitialState)。ユーザー操作の再送はしない(setRunBoardCollapsed と同じ規律)。 */
export function setRunBoardExpandAll(value) {
  if (typeof value !== 'boolean') {
    return;
  }
  expandAll = value;
  render();
}

// 準備中の段階(FTCore.JobPreparingStage の rawValue)→ 文言のキー
const PREPARING_STAGE_KEYS = {
  collectingResults: 'runBoard.preparingStage.collectingResults',
  waitingForRunner: 'runBoard.preparingStage.waitingForRunner',
  checkingRunner: 'runBoard.preparingStage.checkingRunner',
  transferringProject: 'runBoard.preparingStage.transferringProject',
  sendingScenarios: 'runBoard.preparingStage.sendingScenarios',
  startingRun: 'runBoard.preparingStage.startingRun',
};

// run の無い機械の行(行の DOM は run 行と共有する = ensureRow)。バッジと状態(空き / —)だけを
// 出し、開くとその機械のデバイスが並ぶ。**デバイスはその状態に関わらず出す**(停止中でも消さない)。
function updateIdleRow(row, entry) {
  row.run = null;
  row.idle = entry;
  row.rowEl.classList.remove('run-board-row-hasFailed');
  showMachineBadge(row, machineKey(entry.machine));
  row.scopeEl.textContent = '';
  row.runningDevicesEl.style.display = 'none';
  // 空きの行は時刻を持たないので、揃える幅(--rb-lead)ごと畳む(残すと「空き」が右へ押される)
  row.leadEl.style.display = 'none';
  row.progressEl.style.display = 'none';
  row.countsEl.textContent = '';
  row.countsKey = undefined;
  // 空でも箱を残すと列の gap と margin-right ぶん「空き」が右へずれる(ユーザー指摘)ので畳む
  row.countsEl.style.display = 'none';
  row.notesEl.style.display = 'none';
  row.issuerEl.style.display = 'none';
  // 経過の列は箱を残す(畳むと右の列の左端が行ごとにずれる)
  row.timeEl.style.visibility = 'hidden';
  row.remainingEl.style.display = 'none';
  // 空きは語、**不明は「—」**(ユーザー決定)。どちらもグレーで警告色は使わない ——
  // 観測できていないのは異常ではない。**何のダッシュかは title で言う**
  row.statusEl.style.display = '';
  row.statusEl.className = 'run-board-idle-machine-status run-board-machine-state-' + entry.status;
  if (entry.status === 'unknown') {
    row.statusEl.textContent = t('runBoard.remainingUnknown');
    setHoverTip(row.statusEl, t('runBoard.machineUnknown'));
  } else if (entry.preparing && PREPARING_STAGE_KEYS[entry.preparing.stage]) {
    // 対象と対象の間(親が次の run を用意している最中)を「空き」と言わない。未知の段階は「空き」へ倒す
    row.statusEl.textContent = t('runBoard.machinePreparing', {
      stage: t(PREPARING_STAGE_KEYS[entry.preparing.stage]),
      project: entry.preparing.project, profile: entry.preparing.profile,
    });
    setHoverTip(row.statusEl, '');
  } else {
    row.statusEl.textContent = t('runBoard.machineIdle');
    setHoverTip(row.statusEl, '');
  }
  const expandable = renderDevices(row, machineKey(entry.machine), undefined);
  applyRowExpansion(row, expandable);
}

/** 行の先頭のマシン名バッジ(**run の行も空きの行も同じ見た目**。機械の色も同じ)。 */
function showMachineBadge(row, machine) {
  row.machineBadgeEl.style.display = '';
  row.machineBadgeEl.textContent = machineLabel(machine);
  paintMachineBadge(row.machineBadgeEl, machine);
}

/** 三角と行の開閉。子(デバイス・issuer)が無い行の三角は列を揃えるためだけに出す。 */
function applyRowExpansion(row, expandable) {
  const expanded = expandable && isRowExpanded(row);
  row.rowEl.classList.toggle('run-board-row-expanded', expanded);
  row.chevronEl.classList.toggle('run-board-chevron-empty', !expandable);
  row.chevronEl.dataset.expanded = expanded ? 'true' : 'false';
  row.chevronEl.setAttribute('aria-expanded', expanded ? 'true' : 'false');
  // **ツールチップは出さない**(ユーザー決定)—— 名前は読み上げ用の aria-label だけが持つ
  row.chevronEl.setAttribute('aria-label', t(expanded ? 'runBoard.collapseLanes' : 'runBoard.expandLanes'));
}

// 機械のデバイスを行の子に並べる。**その機械のデバイスを全部並べ、run が使っているデバイスにだけ
// シナリオを添える**(ユーザー決定)—— run に出ていないデバイスも見えるようにする。
// デバイスの一覧と並びはラインビュー(monitorDevices)から採る。戻り値 = 1台でも並んだか。
function renderDevices(row, machine, run) {
  row.lanesEl.textContent = '';
  row.laneRows = new Map();
  const devices = devicesOnMachine(machine);
  const laneByKey = new Map((run?.lanes ?? []).map((lane) => [lane.key, lane]));
  // デバイスの一覧に無いレーン(消えたタイル・観測窓の外)も落とさない —— 走っている事実は隠さない
  const extraLanes = (run?.lanes ?? []).filter((lane) => {
    const hit = devices.some((device) => device.laneKey !== undefined && device.laneKey === lane.key);
    return !hit && !(lane.platform !== undefined && !isPlatformVisible(lane.platform));
  });
  for (const device of devices) {
    const lane = device.laneKey === undefined ? undefined : laneByKey.get(device.laneKey);
    appendDeviceLane(row, machine, device.name, lane, run?.receivedAtMs ?? 0, device.platform);
  }
  for (const lane of extraLanes) {
    appendDeviceLane(row, machine, lane.name, lane, run.receivedAtMs, lane.platform);
  }
  renderLaneTimes(row);
  return devices.length > 0 || extraLanes.length > 0;
}

/** その run がこの機械で使っているデバイスをラインビューで選ぶ。 */
function selectRunDevices(run) {
  const ids = [];
  for (const lane of run.lanes) {
    const id = deviceIdForLane(run.machine, lane.key);
    if (id !== undefined) {
      ids.push(id);
    }
  }
  selectOnlyDevices(ids);
}

function toggleRowExpanded(key) {
  const row = rows.get(key);
  if (!row) {
    return;
  }
  const wasExpanded = row.chevronEl.dataset.expanded === 'true';
  const leavingExpandAll = expandAll;
  if (expandAll) {
    // **自動展開を抜ける**: いま全行が開いて見えているので、その姿を個別の記録へ写してから
    // 抜ける(写さないと、1行閉じただけで他の行まで既定の姿に戻って見える)
    for (const other of rows.values()) {
      machineExpansion.set(expansionKey(other), true);
    }
    setExpandAll(false);
  }
  machineExpansion.set(expansionKey(row), !wasExpanded);
  persistMachineExpansion();
  if (leavingExpandAll) {
    // ヘッダのトグルの見た目(ON/OFF)も変わるので、行だけでなく全体を描き直す
    render();
    return;
  }
  // **押したその場で描き直す** —— 次の監視サイクル(約2秒)まで待つと、押してから開くまで
  // 目に見える遅れになる
  if (row.run) {
    updateRow(row, row.run);
  } else if (row.idle) {
    updateIdleRow(row, row.idle);
  }
}

function ensureRow(key) {
  const existing = rows.get(key);
  if (existing) {
    return existing;
  }
  const rowEl = document.createElement('div');
  rowEl.className = 'run-board-row';
  rowEl.dataset.rowKey = key;

  const summaryEl = document.createElement('div');
  summaryEl.className = 'run-board-row-summary';

  // **文字は常に同じ三角**で、向きは CSS の回転で表す(VSCode のツリーと同じ挙動)。
  // 文字を差し替える形(▸/▾)は字面が細く、展開できる行だと気づかれなかった
  const chevronEl = document.createElement('span');
  chevronEl.className = 'run-board-chevron';
  chevronEl.textContent = '▶';
  chevronEl.setAttribute('role', 'button');

  const machineBadgeEl = document.createElement('span');
  machineBadgeEl.className = 'badge badge-remote run-board-machine-badge';

  // マシン名の列(幅は --rb-machine = renderSplit が全行のバッジから決める)
  const machineCellEl = document.createElement('span');
  machineCellEl.className = 'run-board-machine-cell';
  machineCellEl.appendChild(machineBadgeEl);

  const scopeEl = document.createElement('span');
  scopeEl.className = 'run-board-scope';
  // シナリオを実行中のデバイスの数「(3)」(ユーザー決定)。名前(scope)のすぐ右に左寄せで付く(scope は伸ばさない)
  const runningDevicesEl = document.createElement('span');
  runningDevicesEl.className = 'run-board-running-devices';
  runningDevicesEl.style.display = 'none';

  const progressEl = document.createElement('span');
  progressEl.className = 'run-board-progress';
  const progressBarEl = document.createElement('span');
  progressBarEl.className = 'run-board-progress-bar';
  progressEl.appendChild(progressBarEl);

  const countsEl = document.createElement('span');
  countsEl.className = 'run-board-counts';

  const notesEl = document.createElement('span');
  notesEl.className = 'run-board-notes';

  // run の無い機械の行だけが使う(空き / 不明)。run の行では display:none
  const statusEl = document.createElement('span');
  statusEl.className = 'run-board-idle-machine-status';
  statusEl.style.display = 'none';

  // 経過は左右の列の間の独立した列(ユーザー決定)。幅は全行で揃える(--rb-time = renderLeadWidth が測る)
  const timeEl = document.createElement('span');
  timeEl.className = 'run-board-col-time run-board-time';
  // その機械のサーバー(常駐・持ち主なし・停止中。DS-18.10)。マシンの最初の行だけが出す(renderServices)
  const servicesEl = document.createElement('span');
  servicesEl.className = 'run-board-services';
  servicesEl.style.display = 'none';
  const elapsedEl = document.createElement('span');
  elapsedEl.className = 'run-board-elapsed';
  // 経過の右は動画の切り出しの進みだけ(残り時間の見積もりは出さない = 動的な割り振りで当たらない。DR-238)
  const remainingEl = document.createElement('span');
  remainingEl.className = 'run-board-remaining';
  // 動画の切り出しの進みは本数の右(経過の幅を変えてバーの位置をずらさない)
  timeEl.append(elapsedEl);
  remainingEl.style.display = 'none';

  // 2カラム(ユーザー決定): 左 = ツリー・右 = ステータス。**箱の幅は全行で同じ**
  // ので、境目(--rb-left)が行の種類によらず1本に見える
  const leftEl = document.createElement('span');
  leftEl.className = 'run-board-col-left';
  leftEl.append(chevronEl, machineCellEl, scopeEl, runningDevicesEl);
  // 進捗バー・本数または準備中の一言・注記を1つにまとめ、幅を全 run 行で揃える
  // (--rb-lead = renderLeadWidth が最大を測る)= 右に続く状態の左端が行の種類によらず1本に揃う(ユーザー決定)
  const leadEl = document.createElement('span');
  leadEl.className = 'run-board-lead';
  leadEl.append(progressEl, countsEl, notesEl);
  const rightEl = document.createElement('span');
  rightEl.className = 'run-board-col-right';
  rightEl.append(leadEl, statusEl, remainingEl, servicesEl);
  summaryEl.append(leftEl, timeEl, rightEl);

  const issuerEl = document.createElement('div');
  issuerEl.className = 'run-board-issuer';

  const lanesEl = document.createElement('div');
  lanesEl.className = 'run-board-lanes';

  rowEl.append(summaryEl, issuerEl, lanesEl);

  chevronEl.addEventListener('click', (event) => {
    event.stopPropagation();
    toggleRowExpanded(key);
  });
  // 行を押したらその機械のデバイスを選ぶ(run の行は run がこの機械で使っているデバイスだけ)
  summaryEl.addEventListener('click', () => {
    const current = rows.get(key);
    if (!current) {
      return;
    }
    if (current.run) {
      selectRunDevices(current.run);
    } else if (current.idle) {
      selectOnlyDevices(devicesOnMachine(machineKey(current.idle.machine)).map((d) => d.id));
    }
  });

  const row = {
    rowEl, chevronEl, machineBadgeEl, scopeEl, runningDevicesEl, leadEl, progressEl, progressBarEl, countsEl, statusEl, notesEl,
    timeEl, elapsedEl, remainingEl, servicesEl, issuerEl, lanesEl,
    key, run: null, idle: null, laneRows: new Map(),
  };
  rows.set(key, row);
  return row;
}

function renderRowTime(row) {
  const run = row.run;
  if (!run) {
    return;
  }
  const now = Date.now();
  row.elapsedEl.textContent = formatMinSec(liveElapsedSeconds(run.elapsedSeconds, run.receivedAtMs, now));
  row.remainingEl.textContent = run.videoClips
    ? t('runBoard.encodingVideo', { done: String(run.videoClips.done), total: String(run.videoClips.total) })
    : '';
  row.remainingEl.style.display = run.videoClips ? '' : 'none';
}

function renderLaneTimes(row) {
  const now = Date.now();
  for (const entry of row.laneRows.values()) {
    entry.elapsedEl.textContent = formatMinSec(liveElapsedSeconds(entry.base, entry.receivedAtMs, now));
  }
}

// ツリーの1行(= 1台)。`lane` 省略 = そのデバイスは今の run に出ていない(名前だけ出す)。
// machine は machineList() の鍵でも monitorRuns の規約でも受ける(呼び手が揃える)。
function appendDeviceLane(row, machine, name, lane, receivedAtMs, platform) {
  const laneEl = document.createElement('div');
  laneEl.className = 'run-board-lane';

  // デバイスのアイコン(ユーザー決定)。**色はプラットフォームのバッジと同じ**
  // (iOS / Android。CSS の .run-board-lane-icon-* が持つ)。platform を持たないデバイスは
  // 色を付けない(既定の文字色)—— 知らないものを iOS にも Android にも見せない
  const iconEl = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  iconEl.setAttribute('class', 'run-board-lane-icon'
    + (platform === 'ios' || platform === 'android' ? ` run-board-lane-icon-${platform}` : ''));
  iconEl.setAttribute('viewBox', '0 0 16 16');
  iconEl.setAttribute('width', '12');
  iconEl.setAttribute('height', '12');
  iconEl.setAttribute('aria-hidden', 'true');
  const body = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  body.setAttribute('x', '4.2');
  body.setAttribute('y', '1.2');
  body.setAttribute('width', '7.6');
  body.setAttribute('height', '13.6');
  body.setAttribute('rx', '1.8');
  body.setAttribute('fill', 'none');
  body.setAttribute('stroke', 'currentColor');
  body.setAttribute('stroke-width', '1.2');
  const indicator = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  indicator.setAttribute('x', '6.6');
  indicator.setAttribute('y', '11.6');
  indicator.setAttribute('width', '2.8');
  indicator.setAttribute('height', '1.1');
  indicator.setAttribute('rx', '0.55');
  indicator.setAttribute('fill', 'currentColor');
  iconEl.append(body, indicator);

  const nameEl = document.createElement('span');
  nameEl.className = 'run-board-lane-name';
  nameEl.textContent = name;

  const scenarioEl = document.createElement('span');
  scenarioEl.className = 'run-board-lane-scenario';
  // scenario 省略 = そのレーンに今の割り当てが無い(直前の1本を終えて次を待つ。
  // FTCore.RunProgressLane の契約)。**レーンごとの残り本数は持たない**(DS-18.1)。
  const idle = lane !== undefined && lane.scenario === undefined;
  scenarioEl.textContent = lane === undefined ? '' : (idle ? t('runBoard.laneIdle') : `▶ ${scenarioUnitLabel(lane.scenario, lane.variant)}`);

  const elapsedEl = document.createElement('span');
  elapsedEl.className = 'run-board-lane-elapsed';
  // 待機中は経過も無い(「—」は run 側の見積もり無し表示と同じ、i18n を通さない記号)。
  elapsedEl.textContent = idle ? '—' : '';

  const leftEl = document.createElement('span');
  leftEl.className = 'run-board-col-left';
  leftEl.append(iconEl, nameEl);
  const rightEl = document.createElement('span');
  rightEl.className = 'run-board-col-right';
  rightEl.append(scenarioEl, elapsedEl);
  // 経過の列は空のまま幅だけ取る(右の列の左端を run の行と揃える)
  const timeColEl = document.createElement('span');
  timeColEl.className = 'run-board-col-time';
  laneEl.append(leftEl, timeColEl, rightEl);
  // **デバイスの行は押しても何も起きない**(ユーザー決定)—— ここは実行状況を読む場所で、
  // ラインビューの選択を動かす口ではない(選択は機械の行が持つ)
  row.lanesEl.appendChild(laneEl);

  if (lane !== undefined && !idle && lane.scenarioElapsedSeconds !== undefined) {
    row.laneRows.set((machine ?? '') + '\u0000' + lane.key, {
      elapsedEl, base: lane.scenarioElapsedSeconds, receivedAtMs,
    });
  }
}

// 供給の段階(台帳の supply)→「準備中 — 起動中 2・ブリッジを起動中 1(準備完了 0/3 台)」。
// ready 以外の行が無ければ undefined(従来の表示のまま)。
// `whilePreparing` = 準備中の行か(全台 ready の「テストを開始しています」は準備中にだけ出す。実行中は添えない)
function supplyLabel(supply, whilePreparing) {
  const keys = {
    services: 'runBoard.supplyServices', runnerBuild: 'runBoard.supplyRunnerBuild', booting: 'runBoard.supplyBooting',
    bridge: 'runBoard.supplyBridge', configuring: 'runBoard.supplyConfiguring', installing: 'runBoard.supplyInstalling',
    allReady: 'runBoard.supplyStarting',
  };
  const step = currentSupplyStep(supply);
  if (step === undefined || (step === 'allReady' && !whilePreparing)) {
    return undefined;
  }
  return t(keys[step]);
}

// run のある機械の行。**1行に「(マシン名) プロジェクト / 実行プロファイル  進捗  経過 / 残り」**
// (ユーザー決定)。値はこの機械の run のもの —— 機械分担の run は機械ごとに行が分かれ、
// それぞれが自分の進捗を出す。
function updateRow(row, run) {
  row.run = run;
  row.idle = null;
  row.statusEl.style.display = 'none';
  row.leadEl.style.display = '';
  row.countsEl.style.display = '';
  row.timeEl.style.visibility = '';
  row.rowEl.classList.toggle('run-board-row-hasFailed', run.failed > 0);
  showMachineBadge(row, run.machine);

  // profile はプロファイル無し実行(--dry-run 等)では省略されうる(FTCore.RunProgressRecord.profile)。
  row.scopeEl.textContent = run.profile ? `${run.project} / ${run.profile}` : run.project;
  // 実行中のデバイス数 = レーンのうち scenario を持つもの(待機中は含まない。グリッドビューの点灯マークと同じ基準)。
  // 走り出す前(レーンがまだ無い)は出さない
  if (run.phase === 'running') {
    const runningDevices = run.lanes.filter((lane) => lane.scenario).length;
    const text = `(${runningDevices})`;
    if (row.runningDevicesEl.textContent !== text) { row.runningDevicesEl.textContent = text; }
    row.runningDevicesEl.style.display = '';
    setHoverTip(row.runningDevicesEl, t('runBoard.runningDevicesTip'));
  } else {
    row.runningDevicesEl.style.display = 'none';
  }

  // **走り出す前(ビルド中・供給中・Vision のコンパイル待ち)は進捗を出さない** —— 本数も割合もまだ意味を持たない
  // (DS-18.5)。経過だけは出す(どれくらい待っているかが分かる)
  const beforeRunning = run.phase !== 'running';
  row.progressEl.style.display = beforeRunning ? 'none' : '';
  // 供給の段階があれば準備中の文言を詳しくする(無ければ従来のまま。推測で埋めない)
  const supplyText = supplyLabel(run.supply, beforeRunning);
  // countsEl は中身の鍵が前回と同じなら触らない(textContent の代入は子の span を消す = ホバー中のツールチップが周期ごとに消えて出直す。MN-85)
  const countsKey = beforeRunning
    ? JSON.stringify([run.phase, supplyText])
    : JSON.stringify([run.done, run.total, run.failed, RUN_DEVICE_STATES.map(([kind]) => run[kind] > 0 ? run[kind] : 0), supplyText]);
  const countsUnchanged = row.countsKey === countsKey;
  row.countsKey = countsKey;
  if (countsUnchanged) {
    // 変わっていない
  } else if (beforeRunning) {
    // シナリオのビルド中・Vision のコンパイル中はその文言だけ(供給の段階は添えない)。準備中は段階があればそれを1つ
    row.countsEl.textContent = run.phase === 'building' ? t('runBoard.building')
      : run.phase === 'compiling' ? t('runBoard.compiling')
      : (supplyText ?? t('runBoard.preparing'));
  } else {
    const pct = run.total > 0 ? Math.max(0, Math.min(1, run.done / run.total)) * 100 : 0;
    row.progressBarEl.style.width = pct + '%';
    row.countsEl.textContent = `${run.done}/${run.total}`;
    if (run.failed > 0) {
      const failedEl = document.createElement('span');
      failedEl.className = 'run-board-counts-failed';
      failedEl.textContent = `❌${run.failed}`;
      row.countsEl.append(failedEl);
    }
    // この run の中で凍結で離脱した・白紙を検出した・文字消えを検出したデバイスの数。0 の種類は出さない。❌ の後ろに並べる
    for (const [kind, markKey, titleKey] of RUN_DEVICE_STATES) {
      if (!(run[kind] > 0)) continue;
      const stateEl = document.createElement('span');
      stateEl.className = 'run-board-counts-state';
      const markEl = document.createElement('span');
      markEl.textContent = t(markKey);
      markEl.classList.toggle('screen-mark-textless', kind === 'textlessDevices');
      stateEl.append(markEl, String(run[kind]));
      setHoverTip(stateEl, t(titleKey));
      row.countsEl.append(stateEl);
    }
    // 混在 run で iOS の供給が続いている間(最初のレーンが合流して phase は running)
    if (supplyText !== undefined) {
      const supplyEl = document.createElement('span');
      supplyEl.className = 'run-board-counts-supply';
      supplyEl.textContent = supplyText;
      row.countsEl.append(supplyEl);
    }
  }

  // **詰まりは事実だけ**(0 のときは出さない)。「遅い」「異常」とは書かない ——
  // アプリが重いのか機械が混んでいるのかツールには分けられない(DS-18.5)
  const notes = [];
  const noteTips = [];
  if (run.requeued > 0) {
    notes.push(t('runBoard.requeued', { count: String(run.requeued) }));
    noteTips.push(t('runBoard.requeuedTip', { count: String(run.requeued) }));
  }
  if (run.laneDropouts > 0) {
    notes.push(t('runBoard.laneDropouts', { count: String(run.laneDropouts) }));
    noteTips.push(t('runBoard.laneDropoutsTip'));
  }
  row.notesEl.textContent = notes.join('  ');
  // 周期的に描き直すので title ではなく setHoverTip(.claude/rules/vscode-i18n.md)
  setHoverTip(row.notesEl, noteTips.join('\n'));
  row.notesEl.style.display = notes.length > 0 ? '' : 'none';

  const showIssuer = !run.mine && Boolean(run.issuer);
  if (showIssuer) {
    row.issuerEl.textContent = t('runBoard.issuerRun', { issuer: run.issuer });
    row.issuerEl.style.display = '';
  } else {
    row.issuerEl.style.display = 'none';
  }

  renderRowTime(row);
  const hasDevices = renderDevices(row, run.machine, run);
  applyRowExpansion(row, hasDevices || showIssuer);
}

const SERVICES_NOTE_KEYS = {
  running: 'runBoard.servicesRunning', starting: 'runBoard.servicesStarting',
  stopping: 'runBoard.servicesStopping', orphan: 'runBoard.servicesOrphan',
};

/** マシンのサーバー(DS-18.10)。`machine` は machineList() の綴り('' = 手元)。出すのはその機械の最初の行だけ */
function renderServices(row, machine, first) {
  const notes = first ? machineServicesNotes(runsByMachine, machine) : [];
  if (notes.length === 0) {
    row.servicesEl.style.display = 'none';
    setHoverTip(row.servicesEl, '');
    return;
  }
  const byKind = new Map();
  for (const note of notes) {
    const projects = byKind.get(note.kind) ?? [];
    if (!projects.includes(note.project)) { projects.push(note.project); }
    byKind.set(note.kind, projects);
  }
  const text = [...byKind].map(([kind, projects]) => t(SERVICES_NOTE_KEYS[kind], { projects: projects.join(t('runBoard.servicesProjectSeparator')) })).join('  ');
  if (row.servicesEl.textContent !== text) { row.servicesEl.textContent = text; }
  row.servicesEl.classList.toggle('run-board-services-orphan', byKind.has('orphan'));
  row.servicesEl.style.display = '';
  const tipKey = (note) => note.kind === 'orphan' ? 'runBoard.servicesOrphanTip'
    : note.holder === 'run' ? 'runBoard.servicesRunStoppingTip' : 'runBoard.servicesOwnerTip';
  const tip = notes.map((note) => t(tipKey(note), {
    project: note.project, profile: note.profile, pid: String(note.pid),
  })).join('\n');
  setHoverTip(row.servicesEl, tip);
}

// ---- ジョブ(run の上の1階層。ProtocolVersion 76)----------------------------------------------
// run ボードの見出しの行(タコメーターの右)に、ジョブごとの数(run 済 N/M・❌n・実行中・待機)と経過だけを出す。
// 各 run の中身は数のホバーで一覧する。run の行はマシンの行の中のまま。ジョブ単位の残り時間は出さない(見積もりの材料が無い。DR-4)。
// ジョブの鍵(jobKey)→ 見出しの行に置いた要素
const jobRows = new Map();
// 見出しの行でジョブの数と経過を並べる入れ物。**タコメーターの右**(ユーザー決定)。
// 見出しを押すと run ボードが開閉するのは他の部分と同じ
const runBoardHeaderJobs = document.createElement('span');
runBoardHeaderJobs.className = 'run-board-header-jobs';
runBoardHeader.append(runBoardHeaderJobs);

function ensureJobRow(key) {
  const existing = jobRows.get(key);
  if (existing) {
    return existing;
  }
  // 見出しの行(タコメーターの右)に置く数と経過。題名はジョブが2つ以上のときだけ添える(見分けるため)
  const headEl = document.createElement('span');
  headEl.className = 'run-board-header-job';
  headEl.dataset.jobKey = key;
  const titleEl = document.createElement('span');
  titleEl.className = 'run-board-job-title';
  const leadEl = document.createElement('span');
  leadEl.className = 'run-board-job-lead';
  const elapsedEl = document.createElement('span');
  elapsedEl.className = 'run-board-job-elapsed';
  headEl.append(titleEl, leadEl, elapsedEl);
  const row = { key, headEl, titleEl, leadEl, elapsedEl, sig: '', job: null };
  jobRows.set(key, row);
  return row;
}

function jobRunScope(run) {
  return run.profile ? `${run.project} / ${run.profile}` : run.project;
}

function jobCountSpan(className, text) {
  const el = document.createElement('span');
  el.className = className;
  el.textContent = text;
  return el;
}

function updateJobRow(row, job, showTitle) {
  row.job = job;
  // **要素は中身が変わったときだけ作り直す**(周期描画でマウスを載せた数のツールチップが点滅しない)。
  // 鍵 = 表示に効く欄の全部(経過は秒読みで別に書く)
  const sig = JSON.stringify([job.title, job.runs, showTitle]);
  if (row.sig !== sig) {
    row.sig = sig;
    row.titleEl.textContent = showTitle ? `${job.title}:` : '';
    row.titleEl.style.display = showTitle ? '' : 'none';
    const counts = jobCounts(job);
    row.leadEl.textContent = '';
    const doneEl = jobCountSpan('run-board-job-count run-board-job-count-done', t('runBoard.jobDone', {
      done: String(counts.finished), total: String(counts.total),
    }));
    // 「run 済 N/M」のホバーは M 本の全件(終わっていない run も状態付きで)
    setHoverTip(doneEl, jobRunsTip(job, null, 'runBoard.jobAllTip', 'state', counts.finished));
    row.leadEl.append(doneEl);
    if (counts.failed > 0) {
      const failedEl = jobCountSpan('run-board-counts-failed', `❌${counts.failed}`);
      setHoverTip(failedEl, t('runBoard.jobFailedTip'));
      row.leadEl.append(failedEl);
    }
    const runningEl = jobCountSpan('run-board-job-count run-board-job-count-running', t('runBoard.jobRunning', { count: String(counts.running) }));
    setHoverTip(runningEl, jobRunsTip(job, ['running'], 'runBoard.jobRunningTip', 'machines'));
    // 待機中の run は数のホバーで一覧する(並びの行は置かない)
    const pendingEl = jobCountSpan('run-board-job-count run-board-job-count-pending', t('runBoard.jobPending', { count: String(counts.pending) }));
    setHoverTip(pendingEl, jobRunsTip(job, ['pending'], 'runBoard.jobPendingTip', 'none'));
    row.leadEl.append(runningEl, pendingEl);
  }
  renderJobTime(row);
}

/** 見出しの数のホバーに並べる run の行数の上限。
 * 根拠: .hover-tip は 12px × line-height 1.4 ≈ 17px/行で高さの上限もスクロールも無い(pointer-events: none)ので、
 * 30行 + 見出し + 省略の行 ≈ 550px = 600px 程度のパネルに収まる。低いパネルでは下が切れる(見出しは常に見える) */
const JOB_TIP_MAX_RUN_LINES = 30;

/** 上限を超えたときに前から省いてよい状態(済で失敗でないもの)。失敗と未了(実行中・待機)は省かない =
 * 一覧は済 → 実行中 → 待機の順なので、後ろで切ると見たい未了の run が先に消える */
const JOB_TIP_OMITTABLE_KINDS = ['passed', 'skipped', 'canceled'];

/** 一覧の並びの段: 済(終端の4状態)→ 実行中 → 待機 = 実行された/される順。同じ段の中は宣言順 */
const jobTipStage = (kind) => (kind === 'pending' ? 2 : kind === 'running' ? 1 : 0);

/** 見出しの数のホバー: kinds に当たる run の一覧(jobTipStage の順・同じ段は宣言順。番号は並べた順で、省いた分は飛ぶ)。kinds = null は全件
 * (jobCounts の total と同じ集合)。detail = 'state'(状態を添える。実行中はマシン名も)/ 'machines'(マシン名を添える)/ 'none'。
 * done は見出しの {done} に入れる数。上限を超えたら JOB_TIP_OMITTABLE_KINDS を前から省き(先頭に省いた本数)、
 * それでも超える分は末尾を「…ほか N 本」に畳む。該当が無ければ空(ツールチップを出さない) */
function jobRunsTip(job, kinds, titleKey, detail, done = 0) {
  const runs = kinds === null ? job.runs : job.runs.filter((run) => kinds.includes(jobRunKind(run.state)));
  if (runs.length === 0) return '';
  // Array.prototype.sort は安定(ES2019)なので同じ段の中は宣言順のまま
  const all = runs.map((run) => ({ run, kind: jobRunKind(run.state) }))
    .sort((a, b) => jobTipStage(a.kind) - jobTipStage(b.kind))
    .map((entry, index) => ({ ...entry, index }));
  let omitted = 0;
  const kept = all.filter((entry) => {
    if (all.length - omitted > JOB_TIP_MAX_RUN_LINES && JOB_TIP_OMITTABLE_KINDS.includes(entry.kind)) {
      omitted += 1;
      return false;
    }
    return true;
  });
  const lines = kept.slice(0, JOB_TIP_MAX_RUN_LINES).map(({ run, index, kind }) => {
    let text = jobRunScope(run);
    if ((detail === 'machines' || (detail === 'state' && kind === 'running')) && run.machines.length > 0) {
      text = t('runBoard.jobRunWithMachines', { scope: text, machines: run.machines.join(', ') });
    }
    if (detail === 'state') {
      text += ` — ${t(`runBoard.jobState.${kind}`)}`;
    }
    return `${index + 1}. ${text}`;
  });
  if (omitted > 0) {
    lines.unshift(t('runBoard.jobTipOmittedDone', { count: String(omitted) }));
  }
  if (kept.length > JOB_TIP_MAX_RUN_LINES) {
    lines.push(t('runBoard.jobTipMore', { count: String(kept.length - JOB_TIP_MAX_RUN_LINES) }));
  }
  return [t(titleKey, { count: String(runs.length), done: String(done) }), ...lines].join('\n');
}

function renderJobTime(row) {
  const entry = row.job;
  if (entry) {
    row.elapsedEl.textContent = formatMinSec(liveElapsedSeconds(entry.elapsedSeconds, entry.receivedAtMs, Date.now()));
  }
}

function render() {
  const groups = buildRunGroups(runsByMachine);
  const jobs = listJobs(runsByMachine);
  renderHeader(groups, jobs.length);
  // 表示(jobs)ではなく「続いているかもしれない」で止める = 監視が途切れた機械のジョブも数える(不明を空きに倒さない)
  setJobActive(jobsMayBeRunning(runsByMachine));
  // グリッドビューの点灯マーク: いまシナリオを走らせているレーン(scenario あり = 待機中は含まない)のデバイス
  const running = new Set();
  for (const group of groups) {
    for (const run of group.runs) {
      for (const lane of run.lanes) {
        const id = lane.scenario ? deviceIdForLane(run.machine, lane.key) : undefined;
        if (id !== undefined) { running.add(id); }
      }
    }
  }
  setRunningDevices(running);
  const idleByMachine = new Map(
    machinesWithoutRuns(runsByMachine, machineList(), groups).map((e) => [e.machine, e]),
  );

  // **並びは常に機械の順**(machineList = local → 登録簿の順)。run が始まっても機械の位置は
  // 動かさない(ユーザー決定)—— 動くと目が追えない
  const seen = new Set();
  const placeRun = (run) => {
    const key = runRowKey(run);
    seen.add(key);
    const row = ensureRow(key);
    updateRow(row, run);
    // 既存ノードへの appendChild は移動として働く(重複しない)
    runBoardRows.appendChild(row.rowEl);
  };
  // ジョブの数と経過は見出しの行(タコメーターの右)へ。run の行はマシンの行の中のまま(ジョブへ移さない)
  const seenJobs = new Set();
  for (const job of jobs) {
    const key = jobKey(job);
    seenJobs.add(key);
    const jobRow = ensureJobRow(key);
    updateJobRow(jobRow, job, jobs.length > 1);
    runBoardHeaderJobs.appendChild(jobRow.headEl);
  }
  for (const [key, jobRow] of jobRows) {
    if (!seenJobs.has(key)) {
      jobRow.headEl.remove();
      jobRows.delete(key);
    }
  }
  const placedMachines = new Set();
  for (const machine of machineList()) {
    placedMachines.add(machine);
    // 同じ機械で run が複数走っていれば、その機械の行が run の数だけ続く
    for (const group of groups) {
      for (const run of group.runs) {
        if ((run.machine ?? LOCAL_MACHINE_KEY) === machine) {
          placeRun(run);
        }
      }
    }
    const idle = idleByMachine.get(machine);
    if (idle) {
      const key = idleRowKey(machine);
      seen.add(key);
      const row = ensureRow(key);
      updateIdleRow(row, idle);
      runBoardRows.appendChild(row.rowEl);
    }
  }
  // 登録簿に無い機械(無効にした機械を含む)の run も落とさない —— 走っている事実は隠さない
  for (const group of groups) {
    for (const run of group.runs) {
      if (!placedMachines.has(run.machine ?? LOCAL_MACHINE_KEY)) {
        placeRun(run);
      }
    }
  }

  for (const [key, row] of rows) {
    if (!seen.has(key)) {
      row.rowEl.remove();
      rows.delete(key);
    }
  }
  // サーバーは**マシンの最初の行**(空きの行か、その機械の最初の run の行)に出す = DOM の並びで決める
  const servicesShown = new Set();
  for (const el of runBoardRows.children) {
    const row = rows.get(el.dataset.rowKey);
    if (!row) { continue; }
    const machine = row.run ? (row.run.machine ?? LOCAL_MACHINE_KEY) : row.idle.machine;
    renderServices(row, machine, !servicesShown.has(machine));
    servicesShown.add(machine);
  }

  // **行を作り終えてから測る** —— 既定の幅はいちばん長いラベルから決めるので、
  // 行が揃っていないと短い側に決まってしまう
  renderSplit();
  renderLeadWidth();
}

/** run 行の「時刻より前」のまとまりの幅を、いちばん広い行に揃える(--rb-lead)。
 *  自然な幅を測るため一度 0 に戻してから読む(要素は作り直さない)。空きの行は時刻を持たないので対象外 */
function renderLeadWidth() {
  runBoard.style.setProperty('--rb-lead', '0px');
  runBoard.style.setProperty('--rb-time', '0px');
  let widest = 0;
  let widestTime = 0;
  for (const row of rows.values()) {
    if (row.run) {
      widest = Math.max(widest, row.leadEl.offsetWidth);
      widestTime = Math.max(widestTime, row.timeEl.offsetWidth);
    }
  }
  runBoard.style.setProperty('--rb-lead', widest + 'px');
  runBoard.style.setProperty('--rb-time', widestTime + 'px');
}

// ---- アクション/秒メーター(見出しの「実行状況」の右。純粋ロジックは actionTachometerModel.ts) ----
// 中身は最初に1回だけ作り、以後は属性と textContent だけ更新する(周期描画で要素を作り直さない規律。
// マウスを載せている間にツールチップが消えて点滅するのを避ける)。
const SVG_NS = 'http://www.w3.org/2000/svg';
// バーは幅固定(30段 × 7px。段 5px + 隙間 2px)。見出しの幅に引き伸ばさない(ユーザー決定)
const METER_W = 210;
const METER_H = 11;
const TREND_W = 60;
const TREND_H = 18;
/** 推移のチャートの上下左右の余白(px)。線の太さぶん枠で切れないように */
const TREND_PAD = 2;
const tachometer = new ActionTachometer();
const tachoUi = {};
// 数値(アクション/秒)の書式。小数 1 桁(1 目盛り = 1/秒なので、整数に丸めると 1 段に満たない動きが数値に出ない)
const formatPerSecond = (perSecond) => (perSecond ?? 0).toFixed(1);

function svgEl(name, attrs) {
  const el = document.createElementNS(SVG_NS, name);
  for (const [k, v] of Object.entries(attrs)) { el.setAttribute(k, String(v)); }
  return el;
}

function buildTachometer() {
  const meter = svgEl('svg', { class: 'tacho-meter', width: METER_W, height: METER_H,
    viewBox: `0 0 ${METER_W} ${METER_H}`, 'aria-hidden': 'true' });
  tachoUi.meter = meter;
  tachoUi.segs = [];
  ensureSegments(METER_SEGMENTS);
  const value = document.createElement('span');
  value.className = 'tacho-value';
  value.textContent = formatPerSecond(0);
  const unit = document.createElement('span');
  unit.className = 'tacho-unit';
  const trend = svgEl('svg', { class: 'tacho-trend', width: TREND_W, height: TREND_H,
    viewBox: `0 0 ${TREND_W} ${TREND_H}`, 'aria-hidden': 'true' });
  // 線と面は低・中・高で色分けする(段と同じ境目)。線は縦方向のグラデーションを境目で硬く切り替える =
  // 線の高さ(値)でその帯の色になる。境目の位置は縦軸の上限で変わるので drawTrend が offset を書き直す。
  // 面は横方向のグラデーションで、各点の値の帯の色を縦一列に塗る(縦にすると高い時刻でも面の大半が低の色になる)。
  // stop は点の数 × 2 を最初に作り、以後は offset と class だけ書き直す(周期描画で要素を作り直さない)
  // 発光(暗いテーマ)は drop-shadow だと1色しか出せないので、自身をぼかして重ねるフィルタで帯の色のまま光らせる
  const defs = svgEl('defs', {});
  const grad = svgEl('linearGradient', { id: 'tacho-trend-grad', gradientUnits: 'userSpaceOnUse',
    x1: 0, y1: TREND_H - TREND_PAD, x2: 0, y2: TREND_PAD });
  tachoUi.stops = ['low', 'low', 'mid', 'mid', 'high', 'high'].map((tier, i) =>
    svgEl('stop', { class: `tacho-stop-${tier}`, offset: i === 0 ? 0 : 1 })); // 描く前は全部を低に
  grad.append(...tachoUi.stops);
  const areaGrad = svgEl('linearGradient', { id: 'tacho-trend-area-grad', gradientUnits: 'userSpaceOnUse',
    x1: 0, y1: 0, x2: TREND_W, y2: 0 });
  tachoUi.areaStops = Array.from({ length: HM_MAX_SAMPLES * 2 }, () =>
    svgEl('stop', { class: 'tacho-stop-low', offset: 0 }));
  areaGrad.append(...tachoUi.areaStops);
  // 範囲は userSpaceOnUse で描画域ごと取る。既定の objectBoundingBox は線の外接矩形に対する比なので、値が一定の
  // 水平な線(待機中の 0 など)では高さ 0 = フィルタの範囲が空になり、線ごと描かれなくなる
  const glow = svgEl('filter', { id: 'tacho-trend-glow', filterUnits: 'userSpaceOnUse',
    x: -TREND_PAD, y: -TREND_PAD, width: TREND_W + TREND_PAD * 2, height: TREND_H + TREND_PAD * 2 });
  glow.append(svgEl('feGaussianBlur', { in: 'SourceGraphic', stdDeviation: 1, result: 'blur' }));
  const merge = svgEl('feMerge', {});
  merge.append(svgEl('feMergeNode', { in: 'blur' }), svgEl('feMergeNode', { in: 'SourceGraphic' }));
  glow.append(merge);
  defs.append(grad, areaGrad, glow);
  trend.append(defs);
  tachoUi.area = svgEl('path', { class: 'tacho-trend-area', d: '' });
  tachoUi.line = svgEl('path', { class: 'tacho-trend-line', d: '', fill: 'none' });
  trend.append(tachoUi.area, tachoUi.line);
  runBoardTachometer.append(trend, value, unit, meter);
  tachoUi.value = value;
  tachoUi.unit = unit;
}

function setAttrIfChanged(el, name, value) {
  if (el.getAttribute(name) !== value) { el.setAttribute(name, value); }
}
function setTextIfChanged(el, text) {
  if (el.textContent !== text) { el.textContent = text; }
}

// 段の間隔(px)は既定の幅 ÷ 既定の段数で固定し、既定の段数を超える値では同じ間隔の段を右へ足す(右端に張り付かせない)
const SEG_PITCH = METER_W / METER_SEGMENTS;

/** 段を count 個まで用意する。**作った段は消さない**(下がったら隠すだけ = 周期描画で要素を作り直さない規律) */
function ensureSegments(count) {
  for (let i = tachoUi.segs.length; i < count; i += 1) {
    const seg = svgEl('rect', { class: 'tacho-seg', x: (i * SEG_PITCH + 1).toFixed(2),
      y: 0, width: (SEG_PITCH - 2).toFixed(2), height: METER_H, rx: 1,
      'data-tier': segmentTier(i), 'data-lit': '0' });
    tachoUi.meter.appendChild(seg);
    tachoUi.segs.push(seg);
  }
}

function drawMeter() {
  // 数値(アクション/秒)はバーが今表示している値そのもの = バーが 0 なら 0・慣性で一緒に動く(ユーザー決定)
  setTextIfChanged(tachoUi.value, formatPerSecond(tachoUi.shown));
  // 数値の色は、いちばん上に点いている段(途中の段を含む)の色。何も点いていなければ最下段の色
  setAttrIfChanged(tachoUi.value, 'data-tier', segmentTier(Math.max(0, Math.ceil(tachoUi.shown) - 1)));
  // 既定の段数に収まらなければ右へ延ばす(下がれば戻る)。幅は段数 × 間隔
  const count = segmentCount(tachoUi.shown);
  ensureSegments(count);
  const width = (count * SEG_PITCH).toFixed(2);
  setAttrIfChanged(tachoUi.meter, 'width', width);
  setAttrIfChanged(tachoUi.meter, 'viewBox', `0 0 ${width} ${METER_H}`);
  tachoUi.segs.forEach((seg, i) => {
    const shown = i < count;
    if (seg.style.display !== (shown ? '' : 'none')) { seg.style.display = shown ? '' : 'none'; }
    const level = segmentLevel(tachoUi.shown, i);
    setAttrIfChanged(seg, 'data-lit', level > 0 ? '1' : '0');
    // 途中の段だけ薄く点ける(満ちた段・消えた段は既定の不透明度)
    const opacity = level > 0 && level < 1 ? level.toFixed(2) : '';
    if (seg.style.fillOpacity !== opacity) { seg.style.fillOpacity = opacity; }
  });
}

// バーは目標(直近 3 秒の 1 秒あたり)へ慣性で追いつく(easeToward)。元の更新は約 2 秒ごとなので、
// そのまま写すと段々に跳ねる。動いている間だけ requestAnimationFrame を回し、追いついたら止める
// (隠れたパネルでは rAF が止まる)。動きを減らす設定・rAF の無い環境では即座に写す
function stepMeter(ts) {
  const dt = tachoUi.lastFrame === undefined ? 0 : ts - tachoUi.lastFrame;
  tachoUi.lastFrame = ts;
  tachoUi.shown = easeToward(tachoUi.shown, tachoUi.target, dt);
  if (Math.abs(tachoUi.target - tachoUi.shown) < 0.01) { tachoUi.shown = tachoUi.target; }
  drawMeter();
  tachoUi.frame = tachoUi.shown === tachoUi.target ? undefined : requestAnimationFrame(stepMeter);
  if (tachoUi.frame === undefined) { tachoUi.lastFrame = undefined; }
}

function setMeterTarget(perSecond) {
  tachoUi.target = perSecond;
  if (tachoUi.shown === undefined || reduceMotion || typeof requestAnimationFrame !== 'function') {
    tachoUi.shown = perSecond;
    drawMeter();
    return;
  }
  if (tachoUi.frame === undefined && tachoUi.shown !== perSecond) {
    tachoUi.frame = requestAnimationFrame(stepMeter);
  }
}

// 推移のチャートは CPU・GPU のチャートと同じ瞬間に描く(host-metrics の tick = onHostMetricsCommitted。ユーザー決定)。
// 別の時計で描くと隣のチャートと動く瞬間がずれる。host-metrics が来ない間(モニター停止中など)は止まる = 隣と同じ
function drawTrend() {
  if (!tachoUi.segs) { return; }
  // その瞬間にカウンタが表示している値(= バーの値。アクション/秒)を積む = ゲージが 0 ならチャートも 0(ユーザー決定)。
  // CPU・GPU と同じく直近 HM_MAX_SAMPLES 点を右詰めで並べ、古い点は左へ流れて消える
  tachoUi.trendSamples ??= [];
  tachoUi.trendSamples.push(tachoUi.shown ?? 0);
  if (tachoUi.trendSamples.length > HM_MAX_SAMPLES) { tachoUi.trendSamples.shift(); }
  const samples = tachoUi.trendSamples;
  if (samples.length < 2) { return; }
  // y は表示中の最大(最低 1目盛り = 1/秒)に対する比
  const pad = TREND_PAD;
  const trendMax = Math.max(ACTIONS_PER_SECOND_PER_SEGMENT, ...samples);
  const stepX = (TREND_W - pad * 2) / (HM_MAX_SAMPLES - 1);
  const startIndex = HM_MAX_SAMPLES - samples.length;
  const pts = samples.map((v, i) => [
    pad + (startIndex + i) * stepX,
    TREND_H - pad - Math.min(1, v / trendMax) * (TREND_H - pad * 2),
  ]);
  const fmt = (p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`;
  const line = 'M' + pts.map(fmt).join(' L');
  const first = pts[0];
  const last = pts[pts.length - 1];
  setAttrIfChanged(tachoUi.line, 'd', line);
  // 色帯の境目: [低, 低|中の境, 中, 中|高の境, 高, 高] の順に offset を置く(同じ offset の2つで硬く切り替える)
  const { mid, high } = trendTierStops(trendMax);
  [0, mid, mid, high, high, 1].forEach((offset, i) => {
    setAttrIfChanged(tachoUi.stops[i], 'offset', offset.toFixed(4));
  });
  // 面: 点 i はその左右の点との中点までを受け持ち、その間を点 i の値の帯の色で塗る(同じ色の stop を2つ = 色が混ざらない)。
  // 使わない stop(点が 60 に満たない間)は左端の offset 0 に寄せる(stop の offset は昇順でなければならない)
  const unused = tachoUi.areaStops.length - pts.length * 2;
  tachoUi.areaStops.forEach((stop, k) => {
    let offset = 0;
    let tier = valueTier(samples[0]);
    if (k >= unused) {
      const j = k - unused;
      const i = Math.floor(j / 2);
      const x = j % 2 === 0
        ? (i === 0 ? 0 : (pts[i - 1][0] + pts[i][0]) / 2)
        : (i === pts.length - 1 ? TREND_W : (pts[i][0] + pts[i + 1][0]) / 2);
      offset = x / TREND_W;
      tier = valueTier(samples[i]);
    }
    setAttrIfChanged(stop, 'offset', offset.toFixed(4));
    setAttrIfChanged(stop, 'class', `tacho-stop-${tier}`);
  });
  setAttrIfChanged(tachoUi.area, 'd', `${line} L${last[0].toFixed(1)} ${TREND_H} L${first[0].toFixed(1)} ${TREND_H} Z`);
}

onHostMetricsCommitted(drawTrend);

function renderTachometer() {
  if (!tachoUi.segs) { buildTachometer(); }
  const now = Date.now();
  const snap = tachometer.snapshot(now);
  // 説明と読み上げは目標の値(バーが追いついた先)。表示中の数値は drawMeter が毎フレーム書く
  const value = formatPerSecond(snap.meterPerSecond);
  setMeterTarget(snap.meterPerSecond);
  const unit = t('runBoard.tachometerUnit');
  setTextIfChanged(tachoUi.unit, unit);

  const label = (machine) => machineLabel(machine);
  const lines = [t('runBoard.tachometerTipTotal', { value })];
  if (snap.byMachine.length > 1 || (snap.byMachine.length === 1 && snap.byMachine[0].machine !== LOCAL_MACHINE_KEY)) {
    for (const m of snap.byMachine) {
      lines.push(t('runBoard.tachometerTipMachine', { machine: label(m.machine), value: formatPerSecond(m.meterPerSecond) }));
    }
  }
  if (snap.unobservedMachines.length > 0) {
    lines.push(t('runBoard.tachometerTipUnobserved', { machines: snap.unobservedMachines.map(label).join(', ') }));
  }
  lines.push(t('runBoard.tachometerTipDefinition'));
  lines.push(t('runBoard.tachometerTipScale'));
  const tip = lines.join('\n');
  if (runBoardTachometer.getAttribute('data-hover-tip') !== tip) { setHoverTip(runBoardTachometer, tip); }
  setAttrIfChanged(runBoardTachometer, 'aria-label', t('runBoard.tachometerAria', { value }));
  setAttrIfChanged(runBoardTachometer, 'role', 'img');
}

export function setShowTachometer(show) {
  showTachometer = show;
  render();
}

/** main.js の 'monitorRuns' ケースから渡す(1件 = 1機械ぶん。契約は monitorDeviceModel.ts)。 */
export function applyMonitorRuns(message) {
  runsByMachine = applyMonitorRunsEvent(runsByMachine, {
    machine: message.machine,
    observed: message.observed,
    runs: message.runs,
    jobs: message.jobs,
    services: message.services,
  });
  tachometer.apply({ machine: message.machine, observed: message.observed, runs: message.runs }, Date.now());
  render();
  renderTachometer();
}

/** monitor プロセスの(再)起動の合図。machineLocks と同じ寿命 —— 古い run の控えを畳む。 */
export function resetRunBoard() {
  runsByMachine = new Map();
  tachometer.markAllUnobserved();
  render();
  renderTachometer();
}

applyCollapsedUi();
render();
renderTachometer();

// 経過・残りの秒読み(webview の時計)。**DOM は作り直さず数字だけ**書き換える(CLAUDE.md の規律)。
setInterval(() => {
  tachometer.tick(Date.now());
  renderTachometer();
  for (const row of jobRows.values()) {
    renderJobTime(row);
  }
  for (const row of rows.values()) {
    if (row.run) {
      renderRowTime(row);
      renderLaneTimes(row);
    }
  }
}, 1000);
