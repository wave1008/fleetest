#!/usr/bin/env python3
# 回帰(E2E / E2EX / E2EY)を全マシンで1回の `fleetest run --target …` として回す(PT-8.1 → RR-8.2 へ統合)。
# 配り方(空いたマシンが次の対象を取る・終わり際はシナリオ単位で手伝う・待つほうが早ければ待つ)は fleetest run が持つ。
# ここが持つのは run の外側だけ:
#   1. 全マシンで SUT の鮮度を確かめて要ればビルド(各スクリプトの --build-only。マシン間は並列)。
#      リモートはアライン済みのランナーのクローンで起こす = **先に Scripts/align.sh(未コミットの変更も送る)**
#   2. 回帰の対象の一覧(スイート × SUT × OS/モード)を --target に並べて fleetest run を1回
#   3. スクリプトが run ごとにしていた後始末: in-app の証人(E2E-CMP)・画像分類器を使えなかったシナリオを赤にする・
#      全部緑のとき(赤が mark_exclusions.py の表の行だけのときも)検証済みの印・推奨(verification_watch.py stale)・--negative なら陽性対照
# 使えるマシン = この Mac + `fleetest remote machines list --json` の enabled のもの。各プロファイルの devices[].machine が
# 並べたマシンのデバイスだけが使われる(E2EX / E2EY のプロファイルにもリモートの項目がある。スクリプトは --runner local で回す)。
#
# 使い方:
#   FT_FULL_TEST=1 Scripts/regress.py                     # 3 スイート・既定モード(iOS は inapp-boost)+ Android
#   FT_FULL_TEST=1 Scripts/regress.py --ios-xcuitest      # 上に加えて iOS の xcuitest モードの対象も足す
#   FT_FULL_TEST=1 Scripts/regress.py --ios-xcuitest-only # iOS の xcuitest モードの対象だけ(印は xcuitest のものだけ書く)
#   FT_FULL_TEST=1 Scripts/regress.py --suites e2ex,e2ey  # スイートを絞る(--suts flutter,rn で SUT も。絞った回は印を書かない)
#   Scripts/regress.py --dry-run [--ios-xcuitest]         # 対象の一覧と撃つコマンドだけ出す。デバイスを使わない
# 全体の実行なので Scripts/test-scope-guard.py が FT_FULL_TEST=1 を求める(--dry-run は除く)。
import argparse, glob, json, os, shlex, signal, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
import mark_exclusions  # noqa: E402  印の条件から外す赤(e2ex.sh と共有)
FLEETEST = os.path.join(ROOT, ".build", "debug", "fleetest")
REMOTE_CLONE = "~/fleetest-runner/fleetest"
SSH_UNREACHABLE = 255
# 分。段2の前に全マシンのモニター(配信)を止める期限。回帰の実測 25〜30 分(11/9・11/11)の4倍。
# 正常終了・中断では resume で即座に解くので、効くのは regress.py が SIGKILL されたときだけ(尽きると配信が戻るだけ)
MONITOR_HOLD_MINUTES = 120
# 秒。pause の後に配信のプロセスが消えるのを待つ上限(モニターは自分の周期で hold に気づく)。尽きたら残りを名指しして回す
STREAM_TEARDOWN_WAIT = 60

# 段2以降の中断: SIGINT/SIGTERM を受けたら走っている子へ SIGINT を1回だけ伝え、後段へ進まずに終わる。
# 子は別のプロセスグループで起こす(端末の Ctrl-C が子へ直接も届くと二重の SIGINT になる)。
# 自前で受けるのは、`nohup … &` で起こすと bash が SIGINT を無視に設定して Python へ継がせ、既定の KeyboardInterrupt が無いため
_interrupted = False
_child = None


def _on_signal(signum, _frame):
    global _interrupted
    _interrupted = True
    if _child is not None and _child.poll() is None:
        _child.send_signal(signal.SIGINT)


def run_child(cmd, **kwargs):
    global _child
    _child = subprocess.Popen(cmd, cwd=ROOT, process_group=0, **kwargs)
    try:
        while True:
            try:
                return _child.wait()
            except InterruptedError:
                continue
    finally:
        _child = None


def hold_monitors(fleet, action):
    """全マシンのモニターを止める(pause)/戻す(resume)。失敗は名指しして続ける(配信が残っていれば段2の前の確認が言う)"""
    for machine, host in fleet:
        sub = ["monitor", "pause", "--for", str(MONITOR_HOLD_MINUTES)] if action == "pause" else ["monitor", "resume"]
        cmd = [FLEETEST] + sub if host is None else [FLEETEST, "remote", "exec", machine, "--"] + sub
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if out.returncode != 0:
            print(f"   ⚠️ {machine}: monitor {action} が失敗しました(exit {out.returncode}): {(out.stdout + out.stderr).strip()[-200:]}")


def remaining_streams():
    """配信が張られていれば streaming_check.py の警告文、無ければ空文字"""
    return subprocess.run(["python3", os.path.join(ROOT, "Scripts", "streaming_check.py")],
                          capture_output=True, text=True).stdout

# スイート → (スクリプト, プロジェクトの接頭辞, SUT → 回す OS)。**各スクリプトの SUT の表と同じ**(片方だけ変えない)
SUITES = {
    "e2e": ("e2e.sh", "E2E", {"cmp": ("ios", "android"), "ios-native": ("ios",), "android-native": ("android",),
                              "flutter": ("ios", "android"), "rn": ("ios", "android")}),
    "e2ex": ("e2ex.sh", "E2EX", {"cmp": ("ios", "android"), "flutter": ("ios", "android"), "rn": ("ios", "android"),
                                 "android-native": ("android",), "ios-native": ("ios",)}),
    "e2ey": ("e2ey.sh", "E2EY", {"cmp": ("ios", "android"), "flutter": ("ios", "android"), "rn": ("ios", "android"),
                                 "android-native": ("android",), "ios-native": ("ios",)}),
}
PROJECT_SUFFIX = {"cmp": "CMP", "ios-native": "iOS", "android-native": "Android", "flutter": "Flutter", "rn": "RN"}
# in-app ブリッジだけの証人(@Draft = 通常の実行には入らない)。同期相手: Scripts/e2e.sh の run_inapp_witness
WITNESS = ("E2E-CMP", "絵の追いつきを待ってから撮る.S0010")


def build_targets(suites, xcuitest, suts=None, xcuitest_only=False):
    """(スイート, プロジェクト, プロファイル) の一覧。プロファイル名は各スクリプトが回すものと同じ。
    xcuitest_only = iOS の xcuitest モードの対象だけ(inapp-boost と Android は入れない = その印は書かない)"""
    targets = []
    for suite in suites:
        _, prefix, table = SUITES[suite]
        for sut, oses in table.items():
            if suts and sut not in suts:
                continue
            project = f"{prefix}-{PROJECT_SUFFIX[sut]}"
            if "ios" in oses:
                if not xcuitest_only:
                    targets.append((suite, project, "ios-inapp-boost"))
                if xcuitest or xcuitest_only:
                    targets.append((suite, project, "ios-xcuitest"))
            if "android" in oses and not xcuitest_only:
                targets.append((suite, project, "android"))
    return targets


MACHINE_STATE_TIMEOUT = 30   # 秒。ssh の接続 + sysctl と台帳の読みだけ。尽きたら読めなかったと記録して回帰は進める


def run_args(targets, record=False):
    args = [FLEETEST, "run"]
    for _, project, profile in targets:
        args += ["--target", f"{project}:{profile}"]
    return args + ["--set", f"record={'true' if record else 'false'}"]   # 回帰は既定で録画しない(e2e.sh 等の --record と同じ)


def machines():
    out = subprocess.run([FLEETEST, "remote", "machines", "list", "--json"], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"❌ fleetest remote machines list --json が失敗しました: {out.stderr.strip()}")
    doc = json.loads(out.stdout)
    found = []
    if doc.get("local", {}).get("enabled", True):
        found.append(("local", None))
    found += [(h["machine"], h["host"]) for h in doc.get("hosts", []) if h.get("enabled")]
    return found


def command(host, args):
    if host is None:
        return args
    remote = f"cd {REMOTE_CLONE} && {' '.join(shlex.quote(a) for a in args)}"
    # ログイン shell(zsh -lc)= ~/.zprofile の PATH(Scripts/e2ex.sh の --on と同じ)。-tt = 手元が切れたら向こうへ HUP が届く
    return ["ssh", "-tt", "-o", "BatchMode=yes", host, f"zsh -lc {shlex.quote(remote)}"]


def record_machine_states(fleet, run_dir, stage):
    """全マシンの状態(Scripts/machine-state.py)を machine-state.ndjson へ足す。読めないマシンは読めなかった事実を残し、回帰は止めない"""
    def read(machine, host):
        cmd = command(host, ["python3", "Scripts/machine-state.py"])
        try:
            out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, errors="replace",
                                 timeout=MACHINE_STATE_TIMEOUT, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return {"machine": machine, "stage": stage, "unread": f"no answer within {MACHINE_STATE_TIMEOUT}s"}
        except OSError as error:
            return {"machine": machine, "stage": stage, "unread": str(error)}
        line = next((l for l in reversed(out.stdout.splitlines()) if l.strip().startswith("{")), None)
        try:
            state = json.loads(line) if out.returncode == 0 and line else None
        except ValueError:
            state = None
        if not isinstance(state, dict):
            # ssh -tt は向こうの stderr を stdout へ混ぜるので両方の末尾を残す
            tail = (out.stdout + out.stderr).strip()[-200:]
            return {"machine": machine, "stage": stage, "unread": f"exit {out.returncode}: {tail}"}
        return {"machine": machine, "stage": stage, **state}

    rows = [None] * len(fleet)

    def fill(i):
        rows[i] = read(*fleet[i])

    threads = [threading.Thread(target=fill, args=(i,)) for i in range(len(fleet))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    with open(os.path.join(run_dir, "machine-state.ndjson"), "a") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    for row in rows:
        facts = row.get("unread") or " ".join(
            [f"起動 {row['uptimeSeconds'] / 3600:.1f}h" if "uptimeSeconds" in row else "", f"load {row.get('load1', '?')}"]
            + [f"{k}={row[k]['state']}" for k in ("fmText", "fmVision", "videoEncoder") if k in row])
        print(f"   {stage} {row['machine']}: {facts}")


def run_logged(cmd, log_path, env):
    with open(log_path, "w") as log:
        return subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env).returncode


def prebuild_all(fleet, suites, suts, run_dir, env):
    """全マシンで SUT の鮮度確認とビルド(マシン間は並列・マシンの中はスイート順)。失敗したマシンの名前を返す"""
    failed = {}

    def prebuild(machine, host):
        for suite in suites:
            script = SUITES[suite][0]
            # 成果物は iOS のモードに依らない(同じ .app)ので、モードは渡さない
            args = [f"Scripts/{script}", "--build-only"] + [f"--{s}" for s in suts] + (["--local"] if suite == "e2e" else [])
            log = os.path.join(run_dir, f"build-{suite}@{machine}.log")
            code = run_logged(command(host, args), log, env)
            if code != 0:
                why = "届きません" if host is not None and code == SSH_UNREACHABLE else f"{suite} の SUT のビルドに失敗しました"
                failed[machine] = f"{why}({os.path.relpath(log, ROOT)})"
                return
        print(f"   ✅ {machine}: SUT はそろっています")
    threads = [threading.Thread(target=prebuild, args=fm) for fm in fleet]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return failed


def degraded_scenarios(projects, since):
    """見本はあるのに画像分類器を学習・読み込みできなかったシナリオ(注記 vision-classifier-unavailable)。
    checkIsON/OFF は黙って a11y へ倒れ、a11y で読める部品では緑のまま通るので赤にする(同期相手: Scripts/e2e.sh の run_profile)"""
    found = []
    for project in sorted(projects):
        for path in glob.glob(os.path.join(ROOT, "TestProjects", project, "results", "runs", "**", "scenarios", "*.json"),
                              recursive=True):
            if os.path.getmtime(path) < since:
                continue
            with open(path, errors="replace") as f:
                if '"vision-classifier-unavailable"' in f.read():
                    found.append(os.path.relpath(path, ROOT))
    return found


def main():
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description="回帰を全マシンで1回の fleetest run --target として回す")
    ap.add_argument("--suites", default="e2e,e2ex,e2ey")
    ap.add_argument("--suts", default="", help="SUT を絞る(cmp,ios-native,android-native,flutter,rn)。絞った回は検証済みの印を書かない")
    ap.add_argument("--ios-xcuitest", action="store_true", help="iOS の xcuitest モードの対象も足す")
    ap.add_argument("--ios-xcuitest-only", action="store_true",
                    help="iOS の xcuitest モードの対象だけを回す(inapp-boost と Android は回さず、その印も書かない)")
    ap.add_argument("--negative", action="store_true", help="最後に陽性対照(Scripts/e2e-negative.sh)をこの Mac で回す")
    ap.add_argument("--skip-build", action="store_true", help="最初の SUT の鮮度確認・ビルドの段を飛ばす")
    ap.add_argument("--record", action="store_true", help="録画する(既定は --set record=false)")
    ap.add_argument("--dry-run", action="store_true", help="対象の一覧と撃つコマンドだけ出す(デバイスを使わない)")
    opts = ap.parse_args()
    suites = [s for s in opts.suites.split(",") if s]
    unknown = [s for s in suites if s not in SUITES]
    if unknown:
        sys.exit(f"❌ 知らないスイート: {unknown}(e2e / e2ex / e2ey)")
    suts = [s for s in opts.suts.split(",") if s]
    targets = build_targets(suites, opts.ios_xcuitest, suts, opts.ios_xcuitest_only)
    if not targets:
        sys.exit("❌ 回す対象がありません(--suites / --suts を見直してください)")
    witness = "e2e" in suites and ("e2e", WITNESS[0], "ios-inapp-boost") in targets

    if opts.dry_run:
        for suite, project, profile in targets:
            print(f"{suite}: {project}:{profile}")
        print(" ".join(shlex.quote(a) for a in run_args(targets, opts.record)))
        if witness:
            print(f"+ in-app の証人: {WITNESS[0]} / {WITNESS[1]}")
        return 0

    run_dir = os.path.join(ROOT, ".fleetest", "regress", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(run_dir, exist_ok=True)
    env = {**os.environ, "FT_FULL_TEST": "1"}
    started = time.time()
    fleet = machines()
    print(f"==> マシン: {', '.join(m for m, _ in fleet)} / 対象: {len(targets)} / ログ: {run_dir}")
    record_machine_states(fleet, run_dir, "start")

    if not opts.skip_build:
        print("==> 段 1: 全マシンで SUT の鮮度を確かめ、要ればビルドします")
        failed = prebuild_all(fleet, suites, suts, run_dir, env)
        print(f"   段 1 の所要 {time.time() - started:.0f}s")
        if failed:
            # 欠けたマシンを外して回す口は fleetest run に無い(設定タブでマシンを無効にすれば外れる)
            for machine, why in failed.items():
                print(f"   ❌ {machine}: {why}")
            print("❌ SUT をそろえられないマシンがあるので回しません(直すか、設定タブでそのマシンを無効にしてください)")
            record_machine_states(fleet, run_dir, "end")
            return 1

    # 配信は止めてから回す(ユーザー決定 2026-11-11。配信ありの回帰は手元の Android が白紙・固まりで赤になり、
    # 止めて回し直すと通った = 11/1・11/11)。止めた分は終わり・中断のどちらでも finally で戻す
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    print(f"==> 全マシンのモニター(配信)を止めます(最長 {MONITOR_HOLD_MINUTES} 分。終われば戻します)")
    hold_monitors(fleet, "pause")
    try:
        return stage2(opts, fleet, targets, suts, suites, witness, run_dir, env, started)
    finally:
        hold_monitors(fleet, "resume")
        print("→ 全マシンのモニターを戻しました")


def stage2(opts, fleet, targets, suts, suites, witness, run_dir, env, started):
    deadline = time.time() + STREAM_TEARDOWN_WAIT
    streaming = remaining_streams()
    while streaming and time.time() < deadline and not _interrupted:
        time.sleep(2)
        streaming = remaining_streams()
    if streaming:
        print(f"   ⚠️ 止めた後も {STREAM_TEARDOWN_WAIT} 秒で消えなかった配信があります:")
        print(streaming, end="")
    if _interrupted:
        return interrupted_exit(fleet, run_dir)
    print("==> 段 2: fleetest run(空いたマシンが次の対象を取る)")
    run_started = time.time()
    run_ok = run_child(run_args(targets, opts.record), env=env) == 0
    if _interrupted:
        return interrupted_exit(fleet, run_dir)
    witness_ok = True
    if witness:
        print(f"\n═══ {WITNESS[0]} / ios-inapp-boost(in-app の証人: {WITNESS[1]})═══")
        witness_ok = run_child([FLEETEST, "run", "--project", WITNESS[0], "--profile", "ios-inapp-boost",
                                "--scenario", WITNESS[1], "--runner", "local", "--set", "record=false"],
                               env=env) == 0
        if _interrupted:
            return interrupted_exit(fleet, run_dir)
        print(f"{'✅' if witness_ok else '❌'} {WITNESS[0]} / ios-inapp-boost(証人)")
    degraded = degraded_scenarios({p for _, p, _ in targets}, run_started)
    if degraded:
        print("❌ 見本はあるのに画像分類器を使えなかったシナリオがあります(理由はシナリオ末尾の ⚠️ 行)")
        for path in degraded:
            print(f"   {path}")
    record_machine_states(fleet, run_dir, "end")
    print(f"全体の所要: {(time.time() - started) / 60:.1f} 分")

    all_green = run_ok and witness_ok and not degraded
    # 赤が全部「印の条件から外す赤」(mark_exclusions.py)なら印だけは書く。終了コードは赤のまま・外した赤は名指す
    excluded = None if run_ok else mark_exclusions.excluded_reds([(p, q) for _, p, q in targets], run_started)
    if excluded:
        print(f"⚠️ 印の条件から外した赤 {len(excluded)} 本(赤はこれだけ。シナリオは回し続ける):")
        for project, profile, sid, reason in excluded:
            print(f"   {project} / {profile}: {sid}({reason})")
    if (all_green or (excluded and witness_ok and not degraded)) and not suts:
        # スクリプトが全体を回したときと同じ印。iOS の対象をそのモードで全部回したスイートだけ書く
        for suite in suites:
            for mode, profile in (("inapp", "ios-inapp-boost"), ("xcuitest", "ios-xcuitest")):
                if not any(s == suite and p == profile for s, _, p in targets):
                    continue
                digest = subprocess.run([FLEETEST, "api", "bridge-sources", "--bridge", mode, "--digest"],
                                        capture_output=True, text=True)
                if digest.returncode != 0 or not digest.stdout.strip():
                    continue
                marker = os.path.join(ROOT, ".fleetest", f"{mode}-{suite}-verified")
                with open(marker, "w") as f:
                    f.write(digest.stdout)
                print(f"→ {suite} の {mode} 経路を検証済みとして記録しました({os.path.relpath(marker, ROOT)})")
    print("✅ 回帰 全て成功" if all_green else "❌ 回帰に失敗があります")
    if not all_green and streaming:
        print("   ⚠️ この回帰は止めきれなかった配信を残したまま回しました。Android の赤は配信の負荷の可能性があります(段2の前の警告)")

    stale = subprocess.run(["python3", os.path.join(ROOT, "Scripts", "verification_watch.py"), "stale"],
                           capture_output=True, text=True).stdout.strip()
    if stale:
        print("💡 見ている部分が前回 ✅ のときから変わった検証があります(回すのはユーザーの指示があるときだけ):")
        # 書式は Scripts/e2e.sh の末尾と同じ(片方だけ変えない)
        for line in stale.splitlines():
            unit, _, why = line.partition("\t")
            why = "未記録" if why == "never" else "変更あり"
            if unit.startswith("negative:"):
                rest = unit[len("negative:"):]
                project, path = rest.split("/", 1)[0], rest.rsplit("/", 1)[-1]
                print(f"   - 陽性対照 {rest}({why})→ Scripts/e2e-negative.sh --project {project} --file {path}")
            else:
                print(f"   - {unit}({why})→ Scripts/{unit}.sh")

    neg_failed = False
    if opts.negative:
        print("\n═══ 陽性対照(Scripts/e2e-negative.sh)═══")
        neg_failed = run_child([os.path.join(ROOT, "Scripts", "e2e-negative.sh")], env=env) != 0
        if _interrupted:
            return interrupted_exit(fleet, run_dir)
    return 0 if all_green and not neg_failed else 1


def interrupted_exit(fleet, run_dir):
    """中断した回は後段(証人・検証済みの印・推奨・陽性対照)へ進まない。130 = SIGINT で終わった慣例の値"""
    print("\n⛔ 中断しました。後段(証人・検証済みの印・陽性対照)は回しません")
    record_machine_states(fleet, run_dir, "end")
    return 130


if __name__ == "__main__":
    sys.exit(main())
