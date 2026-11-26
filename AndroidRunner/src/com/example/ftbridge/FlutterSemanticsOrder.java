package com.example.ftbridge;

import android.app.UiAutomation;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * POST /semanticsorder の中身。直近の /snapshot の木の仮想ノードについて、Flutter の VM サービスから
 * セマンティクスのダンプ(逆ヒットテスト順)を素の HTTP GET で取って返す。**読むだけ**なので1回撃ち直してよい。
 * ブリッジはダンプを解析しない(並びの解析はホストの FTCore `FlutterSemanticsDump`。Sources/FTCore/SemanticsPaintOrder.swift)。
 * 契約: 成功 {dump, nodes:[{ref, semanticsId, cx, cy}]} / 答えられない {reason}(語彙は REASON_*)。
 */
final class FlutterSemanticsOrder {
    private FlutterSemanticsOrder() {}

    static final String REASON_NO_SNAPSHOT = "no-snapshot";
    static final String REASON_NO_VIRTUAL_NODES = "no-virtual-nodes";
    static final String REASON_MULTIPLE_HOSTS = "multiple-hosts";
    static final String REASON_NO_PID = "no-pid";
    static final String REASON_NO_VM_SERVICE = "no-vm-service";
    static final String REASON_DUMP_FAILED = "dump-failed";
    static final String REASON_TIMEOUT = "timeout";
    static final String REASON_EMPTY_DUMP = "empty-dump";

    /** 1回の HTTP の接続・読みそれぞれの上限(ms)。段0のスクロールの最中の最大 50.1ms の約10倍。尽きたら timeout を返す(ホストは今の挙動のまま) */
    private static final int HTTP_TIMEOUT_MS = 500;
    /**
     * 1回の答えの HTTP の締め切り(ms)。**ブリッジは要求を1本ずつ処理する**(BridgeHttpServer の accept ループ)ので、長引くと次の tap がこの後ろで
     * 待つ。HTTP の呼び出しの前と読みの塊ごとに残りを見て、尽きていれば timeout を返す(残りが HTTP_TIMEOUT_MS より短ければその長さで撃つ)。
     * 値は HTTP 3回(getVM・ダンプ・やり直しの1回)ぶん。**硬い上限ではない**: 接続・応答の頭・1回の読みはそれぞれ最大で残り(≤500ms)まで止まり
     * うるので最悪は約 2.5 秒、さらに上限を持てない shell(pidof・logcat。静止時の実測で数十 ms)が乗る。ホストの上限(5 秒)はその外側
     */
    private static final long ANSWER_BUDGET_MS = 1500;

    private static final Pattern VM_URI = Pattern.compile(
            "The Dart VM service is listening on (http://127\\.0\\.0\\.1:\\d+/[^\\s]*/)");

    // pid ごとの控え(ログは流れて消える・isolate は同じ pid の間は変わらない)。同時リクエストに備え cacheLock で守る
    private static final Object cacheLock = new Object();
    private static final Map<String, String> uriByPid = new HashMap<>();
    private static final Map<String, String> isolateByPid = new HashMap<>();

    private static final class Failure extends Exception {
        final String reason;
        Failure(String reason) { super(reason); this.reason = reason; }
    }

    static JSONObject answer(UiAutomation ua, String pkg, Map<Integer, Integer> virtualIds,
                             Map<Integer, Integer> hostKeys, Map<Integer, double[]> centers) throws JSONException {
        if (pkg == null) return reason(REASON_NO_SNAPSHOT);
        if (virtualIds.isEmpty()) return reason(REASON_NO_VIRTUAL_NODES);
        Set<Integer> hosts = new HashSet<>(hostKeys.values());
        if (hosts.size() > 1) return reason(REASON_MULTIPLE_HOSTS);
        String dump;
        try {
            dump = fetchDump(ua, pkg);
        } catch (Failure f) {
            return reason(f.reason);
        }
        if (dump.trim().isEmpty()) return reason(REASON_EMPTY_DUMP);
        JSONArray nodes = new JSONArray();
        for (int ref : new TreeSet<>(virtualIds.keySet())) {
            double[] c = centers.get(ref);
            if (c == null) continue;
            JSONObject n = new JSONObject();
            n.put("ref", ref);
            n.put("semanticsId", virtualIds.get(ref));
            n.put("cx", c[0]);
            n.put("cy", c[1]);
            nodes.put(n);
        }
        JSONObject o = new JSONObject();
        o.put("dump", dump);
        o.put("nodes", nodes);
        return o;
    }

    private static JSONObject reason(String reason) throws JSONException {
        return new JSONObject().put("reason", reason);
    }

    /** 控えで1回・失敗したら控えを捨ててやり直しで1回(timeout はやり直さない)。全体は ANSWER_BUDGET_MS の中 */
    private static String fetchDump(UiAutomation ua, String pkg) throws Failure {
        long deadline = android.os.SystemClock.uptimeMillis() + ANSWER_BUDGET_MS;
        String pid = pidOf(ua, pkg);
        try {
            return fetchOnce(ua, pid, deadline);
        } catch (Failure first) {
            if (REASON_TIMEOUT.equals(first.reason) || REASON_NO_VM_SERVICE.equals(first.reason)) throw first;
            synchronized (cacheLock) {
                uriByPid.remove(pid);
                isolateByPid.remove(pid);
            }
            return fetchOnce(ua, pid, deadline);
        }
    }

    private static String pidOf(UiAutomation ua, String pkg) throws Failure {
        String out;
        try {
            out = BridgeRouter.rawShell(ua, "pidof " + pkg).trim();
        } catch (RuntimeException e) {
            throw new Failure(REASON_NO_PID);
        }
        if (!out.matches("\\d+")) throw new Failure(REASON_NO_PID);
        return out;
    }

    private static String fetchOnce(UiAutomation ua, String pid, long deadline) throws Failure {
        String uri;
        synchronized (cacheLock) { uri = uriByPid.get(pid); }
        if (uri == null) {
            String log;
            try {
                log = BridgeRouter.rawShell(ua, "logcat -d --pid=" + pid + " -s flutter:I");
            } catch (RuntimeException e) {
                throw new Failure(REASON_DUMP_FAILED);
            }
            Matcher m = VM_URI.matcher(log);
            while (m.find()) uri = m.group(1);
            if (uri == null) throw new Failure(REASON_NO_VM_SERVICE);
            synchronized (cacheLock) { uriByPid.put(pid, uri); }
        }
        String isolate;
        synchronized (cacheLock) { isolate = isolateByPid.get(pid); }
        if (isolate != null) return dumpOf(uri, isolate, deadline);
        // Flutter の UI の isolate は name が main。無ければ先頭の1つだけ試す(isolate を総なめしない = 上限の中に収める)
        JSONArray isolates = isolates(uri, deadline);
        String id = null;
        for (int i = 0; i < isolates.length() && id == null; i++) {
            JSONObject iso = isolates.optJSONObject(i);
            if (iso != null && "main".equals(iso.optString("name"))) id = iso.optString("id", null);
        }
        if (id == null && isolates.length() > 0 && isolates.optJSONObject(0) != null) {
            id = isolates.optJSONObject(0).optString("id", null);
        }
        if (id == null || id.isEmpty()) throw new Failure(REASON_DUMP_FAILED);
        String dump = dumpOf(uri, id, deadline);
        synchronized (cacheLock) { isolateByPid.put(pid, id); }
        return dump;
    }

    private static JSONArray isolates(String uri, long deadline) throws Failure {
        try {
            JSONObject result = new JSONObject(get(uri + "getVM", deadline)).getJSONObject("result");
            return result.getJSONArray("isolates");
        } catch (JSONException e) {
            throw new Failure(REASON_DUMP_FAILED);
        }
    }

    private static String dumpOf(String uri, String isolateId, long deadline) throws Failure {
        try {
            String url = uri + "ext.flutter.debugDumpSemanticsTreeInInverseHitTestOrder?isolateId="
                    + URLEncoder.encode(isolateId, "UTF-8");
            JSONObject result = new JSONObject(get(url, deadline)).getJSONObject("result");
            return result.getString("data");
        } catch (JSONException | java.io.UnsupportedEncodingException e) {
            throw new Failure(REASON_DUMP_FAILED);
        }
    }

    private static String get(String url, long deadline) throws Failure {
        long remaining = deadline - android.os.SystemClock.uptimeMillis();
        if (remaining <= 0) throw new Failure(REASON_TIMEOUT);
        int timeout = (int) Math.min(HTTP_TIMEOUT_MS, remaining);
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setConnectTimeout(timeout);
            conn.setReadTimeout(timeout);
            conn.setRequestMethod("GET");
            if (conn.getResponseCode() != 200) throw new Failure(REASON_DUMP_FAILED);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = conn.getInputStream()) {
                byte[] buf = new byte[8192];
                int n;
                // 読みの上限は read() ごとにかかるので、少しずつ届く応答でも締め切りを大きく越えないよう塊ごとに残りを見る
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                    if (android.os.SystemClock.uptimeMillis() > deadline) throw new Failure(REASON_TIMEOUT);
                }
            }
            return out.toString("UTF-8");
        } catch (SocketTimeoutException e) {
            throw new Failure(REASON_TIMEOUT);
        } catch (java.io.IOException e) {
            throw new Failure(REASON_DUMP_FAILED);
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
