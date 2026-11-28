#!/usr/bin/env python3
# 回帰(E2E / E2EX / E2EY)を全マシンで1回の `fleetest run --target …` として回す(PT-8.1 → RR-8.2 へ統合)。
# 配り方(空いたマシンが次の対象を取る・終わり際はシナリオ単位で手伝う・待つほうが早ければ待つ)は fleetest run が持つ。
# ここが持つのは run の外側だけ:
#   1. 全マシンで SUT の鮮度を確かめて要ればビルド(各スクリプトの --build-only。マシン間もマシンの中のスイートも並列)。
#      リモートはアライン済みのランナーのクローンで起こす = **先に Scripts/align.sh(未コミットの変更も送る)**
#      並行に、各機械の iOS のデバイスとブリッジを手元の `fleetest api start-all-devices` で先に用意する(段2を待たせない。--no-warmup で止める)
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
import regress_placement_checks  # noqa: E402  クラスの寄せ方・run メモのマシン間の共有の検査
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
_warmups = []   # 先に用意する start-all-devices の子(Popen)。中断は段2の子と同じく1回だけ伝える


def _on_signal(signum, _frame):
    global _interrupted
    _interrupted = True
    for proc in [_child] + list(_warmups):
        if proc is not None and proc.poll() is None:
            proc.send_signal(signal.SIGINT)


def run_child(cmd, timed_log=None, **kwargs):
    """timed_log: 出力をそのまま流しつつ、各行に経過秒を付けた写しをこのパスへ書く(段2の所要の内訳を後から読む測る口。
    利用者向けの出力の形は変えない = 行は stdout へそのまま)"""
    global _child
    if timed_log is None:
        _child = subprocess.Popen(cmd, cwd=ROOT, process_group=0, **kwargs)
    else:
        _child = subprocess.Popen(cmd, cwd=ROOT, process_group=0, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  bufsize=1, text=True, errors="replace", **kwargs)
    try:
        if timed_log is not None:
            start = time.time()
            with open(timed_log, "w") as timed:
                for line in _child.stdout:
                    sys.stdout.write(line)
                    timed.write(f"{time.time() - start:8.2f} {line}")
                    timed.flush()
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


def misaligned(fleet):
    """段2で整合チェックに断られるリモート → (理由, アラインで直るか)。段1(SUT のビルド)はこれを見ないので、
    放っておくと断られた分の全対象を手元1台が背負う。見る欄は `fleetest remote status --json` の届く・道具の中身・ツールチェーン
    (ディスパッチの整合チェックが断る条件)"""
    remotes = [(m, h) for m, h in fleet if h is not None]
    if not remotes:
        return {}
    cmd = [FLEETEST, "remote", "status", "--json"]
    for m, _ in remotes:
        cmd += ["--runner", m]
    # cwd = ROOT: 手元の中身の要約は作業ディレクトリのクローンから取る(段2の run と同じ木と比べる)
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    # 食い違い・届かないマシンがあっても JSON を出したうえで exit 1(RemoteCommands の status)= 終了コードでなく中身で見る
    try:
        rows = json.loads(out.stdout).get("hosts", [])
    except (ValueError, AttributeError):
        return {m: (f"fleetest remote status の答えを読めません(exit {out.returncode})", False) for m, _ in remotes}
    # 名前を引けなかった行は host 欄が別名のまま来る = 両方で引く
    by_key = {r.get("host"): r for r in rows}
    found = {}
    for m, host in remotes:
        h = by_key.get(host) or by_key.get(m)
        if h is None:
            found[m] = ("remote status の答えに含まれていません", False)
        elif not h.get("reachable"):
            found[m] = (f"届きません({h.get('error') or '理由の申告なし'})", False)
        elif h.get("xcodeSelectionError") or not h.get("toolchainCompatible", True):
            found[m] = (f"ツールチェーンが手元と合いません({h.get('xcodeSelectionError') or h.get('toolchain')})", False)
        elif not h.get("revisionCompatible"):
            why = ("前回のアラインのビルドが完了していません" if h.get("built") is False
                   else f"道具の中身が手元と食い違います(リモート {str(h.get('digest') or '読めず')[:7]})")
            found[m] = (why, True)
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
    if stage == "start":
        for line in fm_dead_warnings(rows):
            print(line)


def fm_dead_warnings(rows):
    """開始時に FM が dead と記録されたマシンの警告(止めない = 新しい検知は警告から)。FM 無しのテキストの可視性検証は OCR だけで判定し、
    読み誤り(C00→COO 等)で赤になりうる。ANE の no memory(MN-81)は空きメモリがあっても起きる"""
    lines = []
    for row in rows:
        dead = [f"{k}({row[k].get('source') or '?'}, {row[k].get('ageSeconds', '?')}s 前)"
                for k in ("fmText", "fmVision") if isinstance(row.get(k), dict) and row[k].get("state") == "dead"]
        if dead:
            lines.append(f"⚠️  {row['machine']}: FM が止まっている = {' '.join(dead)}。テキストの可視性検証は OCR だけで判定する"
                         " —— このマシンの赤はまず FM の停止を疑う(~/.fleetest/fm-history.ndjson)")
    return lines


def prebuild_args(targets):
    """段2の親の先行ビルド(ScenarioHost.prebuildTogether)と同じ対象を、段1と並行に手元で作る内部口。重複は口の側でも外す"""
    args = [FLEETEST, "api", "prebuild-scenarios"]
    for project in dict.fromkeys(p for _, p, _ in targets):
        args += ["--project", project]
    return args


def start_scenario_prebuild(targets, run_dir, env):
    """手元のシナリオのまとめビルドを背景で起こす。戻り値は join 用のスレッドと結果の入れ物。
    失敗しても回帰は止めない(段2の親が1本ずつ作る)。段2の前に必ず join する = SwiftPM のロックを段2と取り合わない"""
    result = {}

    def work():
        began = time.time()
        try:
            code = run_logged(prebuild_args(targets), os.path.join(run_dir, "prebuild-scenarios.log"), env)
        except OSError as e:
            code = f"起こせませんでした: {e}"
        result["code"] = code
        result["seconds"] = time.time() - began
    thread = threading.Thread(target=work)
    thread.start()
    return thread, result


def finish_scenario_prebuild(thread, result):
    thread.join()
    code = result.get("code")
    state = "完了" if code == 0 else f"失敗({code}。段2が1本ずつ作ります)"
    print(f"   シナリオのまとめビルド: {state} {result.get('seconds', 0):.0f}s(prebuild-scenarios.log)")


def warmup_plan(targets, fleet):
    """段1と並行に先に起動する iOS のデバイスとブリッジ: 機械 → [(プロジェクト, プロファイル)]。
    各機械の iOS の対象のプロファイルの devices[](machine の無い項目は手元)を名前の集合で束ね、既に選んだ集合に含まれるものは撃たない。
    iOS だけ = Simulator の起動枠(SimulatorBootSlots)とブリッジの供給(ProvisionLock)は flock で機械全体に効くので、段2の run と
    重なっても同時起動が増えない。Emulator の起動枠はプロセスの中だけ(ScreenRenderingRecoverer)なので Android は先に起こさない"""
    labels = [m for m, _ in fleet]
    sets = {m: [] for m in labels}
    for _, project, profile in targets:
        if not profile.startswith("ios"):
            continue
        try:
            with open(os.path.join(ROOT, "TestProjects", project, "profiles", "runs", f"{profile}.json")) as f:
                devices = json.load(f).get("devices", [])
        except (OSError, ValueError):
            continue   # 読めないプロファイルは段2の run が名指しして落とす
        for m in labels:
            names = frozenset(d.get("name") for d in devices if d.get("platform") == "ios"
                              and d.get("enabled", True) and (d.get("machine") or "local") == m)
            if names:
                sets[m].append((names, project, profile))
    plan = {}
    for m in labels:
        covered = set()
        for names, project, profile in sorted(sets[m], key=lambda s: -len(s[0])):
            if not names <= covered:
                covered |= names
                plan.setdefault(m, []).append((project, profile))
    return plan


def warmup_jobs(plan):
    """機械ごとの (プロジェクト, プロファイル) を、手元で1回ずつ撃つ順の一覧へ束ねる(同じ組は1回)"""
    jobs = []
    for m in sorted(plan):
        for job in plan[m]:
            if job not in jobs:
                jobs.append(job)
    return jobs


def warmup_command(project, profile):
    # **手元の api start-all-devices を撃つ(リモートで `remote exec <機> -- devices up` を撃たない)** —— remote exec は向こうの
    # work のプロジェクトのコピーを送り直さずに読むので、前の run が送った古いコピーで台を選ぶ(11/28 の回帰で M1Max が割り当て4台の
    # ところ6台を起こそうとした。DR-244)。手元から撃てば RemoteDeviceFanout が毎回そのランナーから見た姿へ書き換えて送ってから起こす
    return [FLEETEST, "api", "start-all-devices", "--project", project, "--profile", profile]


def start_warmup(targets, fleet, run_dir, env):
    """iOS のデバイスとブリッジを背景で用意する(組は順に、各組の中は start-all-devices が機械ごとに並列に起こす)。段2を待たせない ——
    待たせると冷えた Simulator 6台(同時2台・1組 約110秒)の間、全マシンが空く。戻り値は (スレッド, 機械 → 結果)。失敗しても回帰は止めない
    (段2の run が自分で用意する)。機械ごとの終わりは、その機械の deviceFinished を最後に受けた時刻"""
    plan = warmup_plan(targets, fleet)
    jobs = warmup_jobs(plan)
    results = {"began": time.time(), "codes": [], "machines": {}}

    def note(machine, key, value):
        results["machines"].setdefault(machine, {"finished": 0, "failed": 0, "ended": None})[key] = value

    def work():
        with open(os.path.join(run_dir, "warmup.log"), "w") as log:
            for project, profile in jobs:
                if _interrupted:
                    break
                try:
                    proc = subprocess.Popen(warmup_command(project, profile), cwd=ROOT, stdout=subprocess.PIPE,
                                            stderr=log, stdin=subprocess.DEVNULL, env=env, text=True, errors="replace")
                except OSError as e:
                    results["codes"].append(f"起こせませんでした: {e}")
                    continue
                _warmups.append(proc)
                for line in proc.stdout:
                    log.write(line)
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    machine = event.get("machine") or "local"
                    if event.get("kind") == "deviceFinished":
                        m = results["machines"].get(machine, {})
                        note(machine, "finished", m.get("finished", 0) + 1)
                        note(machine, "ended", time.time())
                    elif event.get("kind") == "log" and "❌" in event.get("message", ""):
                        m = results["machines"].get(machine, {})
                        note(machine, "failed", m.get("failed", 0) + 1)
                while True:
                    try:
                        results["codes"].append(proc.wait())
                        break
                    except InterruptedError:
                        continue
        results["ended"] = time.time()

    threads = [threading.Thread(target=work)] if jobs else []
    for t in threads:
        t.start()
    if jobs:
        print("==> 段1と並行: iOS のデバイスとブリッジを先に用意します(" + ", ".join(f"{p}:{q}" for p, q in jobs) + ")")
    return {"threads": threads, "results": results, "done": False}


def finish_warmup(warmup, stage2_started=None):
    """背景の用意を待って、機械ごとの所要と、段2の開始から見た終わりの時刻を出す(段2の準備とどれだけ重なったかを読む測る口)。
    2回目以降は何もしない(段2の後と run_stages の finally の両方から呼ぶ)。失敗の数は start-all-devices が ❌ で言った行"""
    if warmup is None or warmup["done"]:
        return
    warmup["done"] = True
    for t in warmup["threads"]:
        t.join()
    r = warmup["results"]
    if not warmup["threads"]:
        return
    ok = all(c == 0 for c in r["codes"])
    print(f"   先に用意した iOS: {'✅' if ok else '⚠️ ' + str(r['codes'])} {r.get('ended', time.time()) - r['began']:.0f}s(warmup.log)")
    for machine, m in sorted(r["machines"].items()):
        end = "" if stage2_started is None or m["ended"] is None else f" / 段2の開始から {m['ended'] - stage2_started:+.0f}s で終わり"
        failed = f"・失敗 {m['failed']}" if m["failed"] else ""
        span = "" if m["ended"] is None else f" {m['ended'] - r['began']:.0f}s"
        print(f"     {machine}: {m['finished']}台{failed}{span}{end}")


def run_logged(cmd, log_path, env):
    with open(log_path, "w") as log:
        return subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env).returncode


def prebuild_all(fleet, suites, suts, run_dir, env):
    """全マシンで SUT の鮮度確認とビルド(マシン間もマシンの中のスイートも並列)。失敗したマシンの名前を返す。
    スイートの SUT は別のフォルダで成果物もその中。機械で共有するもの(クラッシュダイアログ = 保持者を数える・Flutter の SDK・
    Gradle / CocoaPods のキャッシュ = 各自のロック)は同時に撃っても壊れない"""
    failed = {}

    def prebuild_suite(machine, host, suite, codes):
        script = SUITES[suite][0]
        # 成果物は iOS のモードに依らない(同じ .app)ので、モードは渡さない
        args = [f"Scripts/{script}", "--build-only"] + [f"--{s}" for s in suts] + (["--local"] if suite == "e2e" else [])
        try:
            codes[suite] = run_logged(command(host, args), os.path.join(run_dir, f"build-{suite}@{machine}.log"), env)
        except OSError as e:
            # 起こせなかった(ログを開けない等)も失敗として数える。数えないと KeyError でスレッドだけ死に、そのマシンが成功とも失敗とも言われない
            print(f"   ⚠️ {machine}: {suite} の SUT のビルドを起こせませんでした: {e}")
            codes[suite] = 1

    def prebuild(machine, host):
        codes = {}
        workers = [threading.Thread(target=prebuild_suite, args=(machine, host, s, codes)) for s in suites]
        for t in workers:
            t.start()
        for t in workers:
            t.join()
        # 名指すのはスイート順で最初に落ちたもの(並列でも報告が揺れない)
        for suite in suites:
            code = codes.get(suite, 1)
            if code != 0:
                why = "届きません" if host is not None and code == SSH_UNREACHABLE else f"{suite} の SUT のビルドに失敗しました"
                failed[machine] = f"{why}({os.path.relpath(os.path.join(run_dir, f'build-{suite}@{machine}.log'), ROOT)})"
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
        for path in regress_placement_checks.recent_run_files(project, os.path.join("scenarios", "*.json"), since):
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
    ap.add_argument("--no-warmup", action="store_true",
                    help="段1と並行に iOS のデバイスとブリッジを先に用意しない(効き目を比べるとき)")
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
        print("+ 段1と並行: " + " ".join(shlex.quote(a) for a in prebuild_args(targets)))
        if not opts.no_warmup:
            fleet = machines()
            for project, profile in warmup_jobs(warmup_plan(targets, fleet)):
                print("+ 段1と並行(先に用意): " + " ".join(shlex.quote(a) for a in warmup_command(project, profile)))
        print(" ".join(shlex.quote(a) for a in run_args(targets, opts.record)))
        if witness:
            print(f"+ in-app の証人: {WITNESS[0]} / {WITNESS[1]}")
        return 0

    fleet = machines()
    stale = misaligned(fleet)
    if stale:
        for machine, (why, _) in stale.items():
            print(f"   ❌ {machine}: {why}")
        by_align = [m for m, (_, fixable) in stale.items() if fixable]
        print("❌ 段2で断られるマシンがあるので回しません"
              + (f"(Scripts/align.sh {' '.join(by_align)} の後に回し直してください。アラインの後に作業ツリーへ足したファイル"
                 "(未追跡を含む)も食い違いになります)" if by_align else "")
              + ("。届かない・ツールチェーンの合わないマシンは直すか、設定タブでそのマシンを無効にしてください"
                 if len(by_align) < len(stale) else ""))
        return 1
    run_dir = os.path.join(ROOT, ".fleetest", "regress", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(run_dir, exist_ok=True)
    env = {**os.environ, "FT_FULL_TEST": "1"}
    job_id = begin_job(targets, witness)
    if job_id:
        env["FT_JOB_ID"] = job_id
        env.pop("FT_JOB_MARKED", None)
    try:
        return run_stages(opts, fleet, targets, suts, suites, witness, run_dir, env)
    finally:
        if job_id:
            subprocess.run([FLEETEST, "job", "end", "--id", job_id], capture_output=True, stdin=subprocess.DEVNULL)


def begin_job(targets, witness):
    """回帰の全体をジョブとして宣言する(run ボードに待機中の対象が出る。DS-18.11)。段2の fleetest run は FT_JOB_ID を見て
    外側のこのジョブの行を使う。宣言できなければ None(見える化だけなので回帰は続ける)"""
    rows = [f"{project}:{profile}" for _, project, profile in targets]
    if witness:
        rows.append(f"{WITNESS[0]}:ios-inapp-boost")
    cmd = [FLEETEST, "job", "begin", "--title", "regress", "--owner-pid", str(os.getpid())]
    for row in rows:
        cmd += ["--run", row]
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    job_id = out.stdout.strip() if out.returncode == 0 else ""
    if not job_id:
        print(f"   ⚠️ ジョブを宣言できませんでした(run ボードに待機中の対象が出ません。回帰は続けます): {out.stderr.strip()[-200:]}")
    return job_id or None


def run_stages(opts, fleet, targets, suts, suites, witness, run_dir, env):
    started = time.time()
    print(f"==> マシン: {', '.join(m for m, _ in fleet)} / 対象: {len(targets)} / ログ: {run_dir}")
    record_machine_states(fleet, run_dir, "start")

    # 段2の親が最初にやるシナリオのまとめビルドを、段1(SUT の鮮度確認)と並行に先に済ませる(手元だけ)
    prebuild = start_scenario_prebuild(targets, run_dir, env)
    warmup = None if opts.no_warmup else start_warmup(targets, fleet, run_dir, env)
    try:
        return run_stages_after_prebuild(opts, fleet, targets, suts, suites, witness, run_dir, env, started, prebuild,
                                         warmup)
    finally:
        if prebuild[0].is_alive():
            finish_scenario_prebuild(*prebuild)
        finish_warmup(warmup)


def run_stages_after_prebuild(opts, fleet, targets, suts, suites, witness, run_dir, env, started, prebuild, warmup):
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

    finish_scenario_prebuild(*prebuild)
    # 配信は止めてから回す(ユーザー決定 2026-11-11。配信ありの回帰は手元の Android が白紙・固まりで赤になり、
    # 止めて回し直すと通った = 11/1・11/11)。止めた分は終わり・中断のどちらでも finally で戻す
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    print(f"==> 全マシンのモニター(配信)を止めます(最長 {MONITOR_HOLD_MINUTES} 分。終われば戻します)")
    hold_monitors(fleet, "pause")
    try:
        return stage2(opts, fleet, targets, suts, suites, witness, run_dir, env, started, warmup)
    finally:
        hold_monitors(fleet, "resume")
        print("→ 全マシンのモニターを戻しました")


def stage2(opts, fleet, targets, suts, suites, witness, run_dir, env, started, warmup):
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
    run_ok = run_child(run_args(targets, opts.record), timed_log=os.path.join(run_dir, "stage2.timed.log"), env=env) == 0
    finish_warmup(warmup, run_started)
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
    # クラスの寄せ方(RR-8.3)と run メモのマシン間の共有(DR-208)は緑の run の中では見えないので、結果を読んで確かめる
    placement = regress_placement_checks.placement_findings(run_started)
    if placement:
        print("❌ 1台・1マシンに寄せるはずのクラスが散りました:")
        for line in placement:
            print(f"   {line}")
    memo_failures, memo_unjudged = regress_placement_checks.run_memo_findings(run_started)
    if memo_failures:
        print("❌ run メモがマシンをまたいで届いていません:")
        for line in memo_failures:
            print(f"   {line}")
    for line in memo_unjudged:
        print(f"   ℹ️ run メモのマシン間の共有は判定できませんでした: {line}")
    record_machine_states(fleet, run_dir, "end")
    print(f"全体の所要: {(time.time() - started) / 60:.1f} 分")

    all_green = run_ok and witness_ok and not degraded and not placement and not memo_failures
    # 赤が全部「印の条件から外す赤」(mark_exclusions.py)なら印だけは書く。終了コードは赤のまま・外した赤は名指す
    excluded = None if run_ok else mark_exclusions.excluded_reds([(p, q) for _, p, q in targets], run_started)
    if excluded:
        print(f"⚠️ 印の条件から外した赤 {len(excluded)} 本(赤はこれだけ。シナリオは回し続ける):")
        for project, profile, sid, reason in excluded:
            print(f"   {project} / {profile}: {sid}({reason})")
    if (all_green or (excluded and witness_ok and not degraded and not placement and not memo_failures)) and not suts:
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
        # 陽性対照の run(落ちるのが正常)は回帰のジョブに載せない
        neg_env = {k: v for k, v in env.items() if k not in ("FT_JOB_ID", "FT_JOB_MARKED")}
        neg_failed = run_child([os.path.join(ROOT, "Scripts", "e2e-negative.sh")], env=neg_env) != 0
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
