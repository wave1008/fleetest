#!/usr/bin/env python3
# この Mac の状態を1行の JSON で出す(読むだけ)。回帰の赤をマシンの劣化と切り分ける材料(Scripts/regress.py が開始・終了と段2の間 15 秒ごとに記録する)。
# 書き手の台帳 ~/.fleetest/{fm-liveness,video-encoder-liveness}.json を読むだけで、FM もエンコーダも撃たない。
# 欄の契約: 読めない値は欄ごと省く(0 や dead で埋めない)。ageSeconds が大きい観測は古い = 今の状態とは言えない。
# 判定は置かない(「劣化」と言えるのは人が run と突き合わせたときだけ)。
import json, os, re, socket, subprocess, time


def uptime_seconds(now):
    out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True)
    match = re.search(r"sec = (\d+)", out.stdout) if out.returncode == 0 else None
    return round(now - int(match.group(1))) if match else None


def ledger(name):
    try:
        with open(os.path.join(os.path.expanduser("~/.fleetest"), name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def verdict(entry, now):
    if not isinstance(entry, dict) or "state" not in entry or "checkedAt" not in entry:
        return None
    return {"state": entry["state"], "source": entry.get("source"), "ageSeconds": round(now - entry["checkedAt"])}


def sysctl_int(name):
    out = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True)
    try:
        return int(out.stdout.strip()) if out.returncode == 0 else None
    except ValueError:
        return None


def vm_bytes():
    """vm_stat の空きと圧縮器(圧縮後)のバイト数。ページの大きさは vm_stat の1行目が言う値(Apple Silicon は 16384)"""
    out = subprocess.run(["vm_stat"], capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    page = re.search(r"page size of (\d+) bytes", out.stdout)
    if not page:
        return {}
    found = {}
    for key, label in (("freeBytes", "Pages free"), ("compressedBytes", "Pages occupied by compressor")):
        match = re.search(rf"^{label}:\s+(\d+)\.", out.stdout, re.M)
        if match:
            found[key] = int(match.group(1)) * int(page.group(1))
    return found


def booted_devices():
    """起動中の Simulator(simctl の Booted)と Emulator(qemu のプロセス)の数。読めない側は欄ごと省く"""
    found = {}
    sims = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"], capture_output=True, text=True, timeout=20)
    if sims.returncode == 0:
        try:
            found["bootedSimulators"] = sum(
                1 for devices in json.loads(sims.stdout).get("devices", {}).values() for d in devices if d.get("state") == "Booted")
        except ValueError:
            pass
    # pgrep は一致なしで 1 を返す(= 0 台)。2 以上は読めなかった
    qemu = subprocess.run(["pgrep", "-f", "qemu-system-"], capture_output=True, text=True)
    if qemu.returncode in (0, 1):
        found["runningEmulators"] = len(qemu.stdout.split())
    return found


def memory_state():
    """メモリの逼迫を見る材料(DR-242 の段0)。memorystatus_vm_pressure_level は 1=通常・2=警告・4=危険、
    memorystatus_level は利用可能な割合(%)。どちらも root 不要の sysctl"""
    found = {}
    level = sysctl_int("kern.memorystatus_vm_pressure_level")
    if level is not None:
        found["memoryPressureLevel"] = level
    available = sysctl_int("kern.memorystatus_level")
    if available is not None:
        found["memoryAvailablePercent"] = available
    found.update(vm_bytes())
    try:
        found.update(booted_devices())
    except (OSError, subprocess.TimeoutExpired):
        pass
    return found


def main():
    now = time.time()
    state = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "host": socket.gethostname(), "cpuCount": os.cpu_count()}
    uptime = uptime_seconds(now)
    if uptime is not None:
        state["uptimeSeconds"] = uptime
    try:
        state["load1"], state["load5"], _ = [round(v, 1) for v in os.getloadavg()]
    except OSError:
        pass
    fm = ledger("fm-liveness.json") or {}
    for key in ("text", "vision"):
        found = verdict(fm.get(key), now)
        if found:
            state[f"fm{key.capitalize()}"] = found
    encoder = verdict(ledger("video-encoder-liveness.json"), now)
    if encoder:
        state["videoEncoder"] = encoder
    state.update(memory_state())
    print(json.dumps(state, ensure_ascii=False))


if __name__ == "__main__":
    main()
