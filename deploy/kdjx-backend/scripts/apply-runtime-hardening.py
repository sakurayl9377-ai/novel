#!/usr/bin/env python3
"""Apply narrow network hardening patches before building KDJX binaries."""

from __future__ import print_function

import argparse
import sys
from pathlib import Path


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def replace_once(path, old, new, label):
    content = path.read_text(encoding="utf-8")
    if new and new in content:
        return
    if not new and old not in content:
        return
    if content.count(old) != 1:
        fail("{} does not match the supported source layout".format(label))
    path.write_text(content.replace(old, new, 1), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    path = root / "gosrc" / "tjgame" / "anti_cheat" / "main.go"
    if not path.is_file():
        fail("KDJX anti-cheat source is missing: {}".format(path))
    replace_once(
        path,
        "\t\"tjgame/server_framework/tj/util\"\n",
        "",
        "anti-cheat metrics import",
    )
    replace_once(
        path,
        "\tlocalIP := util.GetLocalIP()\n\taddr := fmt.Sprintf(\"%s:2112\", localIP)",
        "\taddr := \"127.0.0.1:2112\"",
        "anti-cheat metrics listener",
    )
    replace_once(
        path,
        "\t\"fmt\"\n",
        "",
        "anti-cheat metrics fmt import",
    )
    forward = root / "gosrc" / "tjgame" / "services" / "cross" / "onlinefight" / "forward" / "service.go"
    if not forward.is_file():
        fail("KDJX online-fight-forward source is missing: {}".format(forward))
    replace_once(
        forward,
        "runner := NewAntiProxyRunner(patch)",
        "runner := NewAntiProxyLuaRunner(patch)",
        "online-fight legacy agent runner",
    )
    replace_once(
        forward,
        "runner.(*AntiProxyRunner).Stop()",
        "runner.(*AntiProxyLuaRunner).Stop()",
        "online-fight Lua runner shutdown",
    )
    replace_once(
        forward,
        "old.(*AntiProxyRunner).NoBattleStop()",
        "old.(*AntiProxyLuaRunner).NoBattleStop()",
        "online-fight Lua runner rollover",
    )
    replace_once(
        forward,
        "\n\tgo func() {\n\t\t<-runner.Done()\n\t\ts.reloadProxyRunner(currentPatch)\n\t}()\n",
        "",
        "online-fight legacy agent restart watcher",
    )

    proxy = root / "gosrc" / "tjgame" / "services" / "cross" / "onlinefight" / "forward" / "proxy.go"
    if not proxy.is_file():
        fail("KDJX online-fight proxy source is missing: {}".format(proxy))
    replace_once(
        proxy,
        "\tpatch   int\n\tcurrent int\n\texited  bool // if true, no battle will auto stop runner\n}",
        "\tpatch   int\n\tcurrent int\n\texited  bool // if true, no battle will auto stop runner\n\tstopped bool\n}",
        "online-fight Lua runner state",
    )
    replace_once(
        proxy,
        """func (r *AntiProxyLuaRunner) Stop() {
\tlog.Infof(\"Stopping Runner[%d]\", r.idx)
\tif err := r.closer.Close(); err != nil {
\t\tlog.Errorf(\"Close Runner[%d] error %v\", r.idx, err)
\t}
\tif err := r.cmd.Wait(); err != nil {
\t\tlog.Errorf(\"Stop Runner[%d] error %v\", r.idx, err)
\t}
}""",
        """func (r *AntiProxyLuaRunner) Stop() {
\tr.mu.Lock()
\tif r.stopped {
\t\tr.mu.Unlock()
\t\treturn
\t}
\tr.stopped = true
\tr.mu.Unlock()

\tlog.Infof(\"Stopping Runner[%d]\", r.idx)
\tif err := r.closer.Close(); err != nil {
\t\tlog.Errorf(\"Close Runner[%d] error %v\", r.idx, err)
\t}
\tif err := r.cmd.Wait(); err != nil {
\t\tlog.Errorf(\"Stop Runner[%d] error %v\", r.idx, err)
\t}
}""",
        "online-fight Lua runner stop",
    )
    replace_once(
        proxy,
        """func (r *AntiProxyLuaRunner) StartBattle(record *scheme.CrossOnlineFightPlayRecord) (*ProxyRunnerResponse, error) {
\tdata, err := util.MsgPack(record)
\tif err != nil {
\t\treturn nil, err
\t}
\tr.mu.Lock()
\tdefer r.mu.Unlock()
\treturn r.tolua(record.ID, \"start\", data)
}""",
        """func (r *AntiProxyLuaRunner) StartBattle(record *scheme.CrossOnlineFightPlayRecord) (*ProxyRunnerResponse, error) {
\tdata, err := util.MsgPack(record)
\tif err != nil {
\t\treturn nil, err
\t}
\tr.mu.Lock()
\tdefer r.mu.Unlock()
\tresponse, err := r.tolua(record.ID, \"start\", data)
\tif err == nil {
\t\tr.current++
\t}
\treturn response, err
}""",
        "online-fight Lua runner battle start",
    )
    replace_once(
        proxy,
        """func (r *AntiProxyLuaRunner) CloseBattle(id document.ID) (*ProxyRunnerResponse, error) {
\treturn r.tolua(id, \"close\", []byte{})
}""",
        """func (r *AntiProxyLuaRunner) CloseBattle(id document.ID) (*ProxyRunnerResponse, error) {
\tr.mu.Lock()
\tresponse, err := r.tolua(id, \"close\", []byte{})
\tif err == nil && r.current > 0 {
\t\tr.current--
\t}
\tstop := r.exited && r.current == 0
\tr.mu.Unlock()
\tif stop {
\t\tr.Stop()
\t}
\treturn response, err
}""",
        "online-fight Lua runner battle close",
    )
    replace_once(
        proxy,
        """func (r *AntiProxyLuaRunner) NoBattleStop() {
\tr.mu.Lock()
\tdefer r.mu.Unlock()
\tr.exited = true
\tif r.current == 0 {
\t\tr.Stop()
\t}
}""",
        """func (r *AntiProxyLuaRunner) NoBattleStop() {
\tr.mu.Lock()
\tr.exited = true
\tstop := r.current == 0
\tr.mu.Unlock()
\tif stop {
\t\tr.Stop()
\t}
}""",
        "online-fight Lua runner idle stop",
    )

    rpcserver = root / "gosrc" / "tjgame" / "server_framework" / "tj" / "nsq" / "rpcserver.go"
    if not rpcserver.is_file():
        fail("KDJX NSQ RPC source is missing: {}".format(rpcserver))
    replace_once(
        rpcserver,
        '\tqueryUrl := fmt.Sprintf("http://%s/stats?topic=%s&channel=%s&format=json", nsqdHTTP, url.QueryEscape(topic), url.QueryEscape(channel))',
        """\tstatsURL := url.URL{Scheme: "http", Host: nsqdHTTP, Path: "/stats"}
\tquery := statsURL.Query()
\tquery.Set("topic", topic)
\tquery.Set("channel", channel)
\tquery.Set("format", "json")
\tstatsURL.RawQuery = query.Encode()
\tqueryUrl := statsURL.String()""",
        "NSQ loopback stats URL",
    )
    replace_once(
        rpcserver,
        '\ttopics := stats["topics"].([]interface{})',
        """\ttopics, ok := stats["topics"].([]interface{})
\tif !ok {
\t\treturn 0
\t}""",
        "NSQ empty stats response",
    )


if __name__ == "__main__":
    main()
