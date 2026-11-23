#!/usr/bin/env python3
"""forksmartdns WebUI — reproducible self-test.

Runs without a router or Docker. It needs Python 3.9+, a POSIX shell and
BusyBox with the `httpd` applet (busybox-w32 works on Windows).

  BUSYBOX=/path/to/busybox python3 tests/selftest.py

What is covered:
  * static config validator;
  * CGI API: auth, CSRF, config get/validate/block, backups, files, logs;
  * real HTTP through BusyBox httpd + CGI (cookies, CSRF, static, traversal);
  * install.sh -> upgrade -> uninstall.sh in a throw-away prefix;
  * a fake resolver binary is used (the real kernel is not executed).

What is NOT covered: a real smartdns/hrdns process, real DNS answers, aarch64,
lighttpd and Keenetic. See docs/TEST-REPORT.md.
"""
import hashlib
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from functools import partial
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
BUSYBOX = os.environ.get("BUSYBOX") or shutil.which("busybox")
WORK = Path(os.environ.get("FSD_TEST_WORK") or tempfile.mkdtemp(prefix="fsd-selftest-"))
BBIN = WORK / "bbin"
PASS = 0
FAIL = 0
APPLETS = ["sh", "ash", "awk", "sed", "grep", "tr", "cut", "head", "tail", "wc", "sha256sum",
           "od", "date", "mkdir", "rm", "cp", "mv", "chmod", "find", "tar", "gzip", "sleep",
           "nc", "wget", "xargs", "sort", "uniq", "printf", "dirname", "basename", "readlink",
           "stat", "df", "uname", "hostname", "cat", "ls", "test", "true", "false", "tee",
           "touch", "mktemp", "busybox", "pgrep"]


def check(name, cond, info=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("PASS", name)
    else:
        FAIL += 1
        print("FAIL", name, info)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def setup_applets():
    BBIN.mkdir(parents=True, exist_ok=True)
    for app in APPLETS:
        dst = BBIN / (app + ".exe" if os.name == "nt" else app)
        if dst.exists():
            continue
        try:
            os.link(BUSYBOX, dst)
        except Exception:
            shutil.copy2(BUSYBOX, dst)


def base_env(prefix):
    env = dict(os.environ)
    env["PATH"] = str(BBIN) + os.pathsep + env.get("PATH", "")
    env["FORKSMDNS_PREFIX"] = str(prefix).replace("\\", "/")
    env["FSD_HASH_ITER"] = "2"
    env["TMP"] = str(WORK / "tmp")
    env["TEMP"] = str(WORK / "tmp")
    env["TMPDIR"] = str(WORK / "tmp")
    return env


def build_instance(root):
    """Create a minimal installed-looking prefix for direct CGI/API tests."""
    if root.exists():
        shutil.rmtree(root)
    prefix = root / "opt"
    etc = prefix / "etc" / "forksmartdns"
    lib = prefix / "share" / "forksmartdns"
    var = prefix / "var" / "lib" / "forksmartdns"
    log = prefix / "var" / "log" / "forksmartdns"
    run = prefix / "var" / "run" / "forksmartdns"
    for d in [etc / "bin", etc / "lists", lib / "lib", lib / "cgi", lib / "www" / "cgi-bin",
              lib / "bin", lib / "etc", lib / "docs", var / "backups", var / "tmp", log, run,
              prefix / "etc" / "init.d", prefix / "bin"]:
        d.mkdir(parents=True, exist_ok=True)
    for p in (PROJECT / "src" / "lib").glob("*"):
        shutil.copy2(p, lib / "lib" / p.name)
    shutil.copy2(PROJECT / "src" / "cgi" / "api.cgi", lib / "cgi" / "api.cgi")
    shutil.copy2(PROJECT / "src" / "cgi" / "api.cgi", lib / "www" / "cgi-bin" / "api.cgi")
    for p in (PROJECT / "src" / "www").glob("*"):
        if p.is_file():
            shutil.copy2(p, lib / "www" / p.name)
    for name in ["schema.tsv", "directives.txt"]:
        shutil.copy2(PROJECT / "src" / "etc" / name, lib / "www" / name)
    for name in ["forksmartdns.conf.in", "lighttpd.conf.in"]:
        shutil.copy2(PROJECT / "src" / "etc" / name, lib / "etc" / name)
    shutil.copy2(PROJECT / "src" / "bin" / "forksmartdnsctl", lib / "bin" / "forksmartdnsctl")
    shutil.copy2(PROJECT / "src" / "init" / "forksmartdns.init", prefix / "etc" / "init.d" / "forksmartdns")
    core = etc / "bin" / "core"
    core.write_text("#!/bin/sh\n"
                    "if [ \"${1:-}\" = \"-v\" ]; then echo 'hrdns 1.2.3-test'; exit 0; fi\n"
                    "if [ \"${1:-}\" = \"--is-quic-supported\" ]; then echo 'quic is supported.'; exit 0; fi\n"
                    "echo 'hrdns starting...(fake core)'\n"
                    "trap 'exit 0' TERM INT\n"
                    "i=0; while [ $i -lt 5 ]; do i=$((i+1)); sleep 1; done\n", encoding="utf-8")
    core.chmod(0o755)
    tpl = (lib / "etc" / "forksmartdns.conf.in").read_text(encoding="utf-8")
    conf = (tpl.replace("@DNS_BIND@", "127.0.0.1").replace("@DNS_PORT@", "5353")
            .replace("@UI_INTERNAL_PORT@", "36390")
            .replace("@VAR@", str(var).replace("\\", "/")).replace("@LOG@", str(log).replace("\\", "/")))
    (etc / "forksmartdns.conf").write_text(conf, encoding="utf-8")
    (etc / "instance.env").write_text(
        "FSD_VERSION='0.1.0-pre1'\nFSD_UI_PORT=3636\nFSD_UI_BIND='127.0.0.1'\n"
        "FSD_DNS_PORT=5353\nFSD_DNS_BIND='127.0.0.1'\nFSD_UI_INTERNAL_PORT=36390\n"
        "FSD_WEB_SERVER='busybox'\nFSD_CORE_KIND='hrdns'\n"
        f"FSD_CORE_BIN='{core}'\n", encoding="utf-8")
    (etc / "setup-token").write_text("setup-token-test\n", encoding="utf-8")
    for p in [lib / "bin" / "forksmartdnsctl", lib / "cgi" / "api.cgi",
              lib / "www" / "cgi-bin" / "api.cgi", prefix / "etc" / "init.d" / "forksmartdns"]:
        p.chmod(0o755)
    return {"prefix": prefix, "etc": etc, "lib": lib, "var": var, "log": log, "run": run}


class CGI:
    def __init__(self, inst):
        self.inst = inst
        self.cookie = None
        self.csrf = None

    def call(self, method, action, params=None, body=b"", cookies=None, csrf=None):
        q = {"action": action}
        q.update(params or {})
        qs = urllib.parse.urlencode(q)
        env = base_env(self.inst["prefix"])
        env.update({
            "REQUEST_METHOD": method, "QUERY_STRING": qs, "REQUEST_URI": "/cgi-bin/api.cgi?" + qs,
            "CONTENT_LENGTH": str(len(body)), "CONTENT_TYPE": "application/x-www-form-urlencoded",
            "REMOTE_ADDR": "192.168.1.50", "HTTP_HOST": "192.168.1.1:3636",
        })
        if cookies:
            env["HTTP_COOKIE"] = cookies
        if csrf:
            env["HTTP_X_FSD_CSRF"] = csrf
        p = subprocess.run([BUSYBOX, "ash", str(self.inst["lib"] / "cgi" / "api.cgi")],
                           input=body, capture_output=True, env=env, timeout=120)
        raw = p.stdout
        sep = raw.find(b"\r\n\r\n")
        if sep < 0:
            sep = raw.find(b"\n\n")
        head, payload = (raw[:sep], raw[sep + 4:]) if sep >= 0 else (raw, b"")
        status = 0
        headers = {}
        for line in head.replace(b"\r\n", b"\n").split(b"\n"):
            line = line.decode("utf-8", "replace")
            if line.lower().startswith("status:"):
                try:
                    status = int(line.split()[1])
                except Exception:
                    pass
            elif ":" in line:
                k, v = line.split(":", 1)
                headers.setdefault(k.strip().lower(), []).append(v.strip())
        try:
            js = json.loads(payload.decode("utf-8"))
        except Exception:
            js = None
        return status, headers, payload, js

    def api(self, action, method="GET", params=None, form=None, raw=None):
        body = b""
        if form is not None:
            body = urllib.parse.urlencode(form).encode()
        elif raw is not None:
            body = raw.encode("utf-8") if isinstance(raw, str) else raw
        return self.call(method, action, params, body, self.cookie, self.csrf)


def test_api(inst):
    c = CGI(inst)
    st, h, raw, js = c.api("session")
    check("api: session before setup", st == 200 and js and js["data"]["setup_required"], (st, raw[:120]))
    st, h, raw, js = c.api("setup", "POST", form={"token": "bad", "password": "Secret123!"})
    check("api: wrong setup token", st == 403, st)
    st, h, raw, js = c.api("setup", "POST", form={"token": "setup-token-test", "password": "Secret123!"})
    check("api: setup", st == 200 and js and js["ok"], (st, raw[:200]))
    for s in h.get("set-cookie", []):
        if s.startswith("fsd_session="):
            c.cookie = s.split(";", 1)[0]
    c.csrf = js["data"]["csrf"] if js else None
    check("api: cookie + csrf", bool(c.cookie and c.csrf))

    st, h, raw, js = c.api("status")
    check("api: status", st == 200 and js and js["ok"] and js["data"]["config"]["exists"], (st, raw[:150]))

    st, h, raw, js = c.api("config.get")
    check("api: config blocks", st == 200 and "fsd:upstreams" in js["data"]["raw"], (st, raw[:150]))

    st, h, raw, js = c.api("config.validate", "POST", params={"runtime": "0"}, raw="bogus-directive yes\n")
    check("api: validator rejects unknown", js and js["data"]["valid"] is False and js["data"]["errors"], st)

    conf = (inst["etc"] / "forksmartdns.conf").read_text(encoding="utf-8")
    st, h, raw, js = c.api("config.validate", "POST", params={"runtime": "0"}, raw=conf)
    check("api: validator accepts config", js and js["data"]["valid"] is True, st)

    st, h, raw, js = c.api("config.block", "POST", params={"name": "upstreams"}, raw="server 9.9.9.9\n")
    check("api: apply block", st == 200 and js and js["ok"], (st, raw[:200]))
    st, h, raw, js = c.api("config.get")
    check("api: block persisted", "9.9.9.9" in js["data"]["blocks"]["upstreams"])
    st, h, raw, js = c.call("POST", "config.block", {"name": "upstreams"}, b"server 8.8.8.8\n", c.cookie, None)
    check("api: csrf required", st == 403, st)

    st, h, raw, js = c.api("files.write", "POST", params={"name": "test.txt"}, raw="example.com\n")
    check("api: file write", st == 200 and js and js["ok"], st)
    st, h, raw, js = c.api("files.read", params={"name": "test.txt"})
    check("api: file read", js and js["data"]["content"] == "example.com\n", js)
    st, h, raw, js = c.api("files.list")
    check("api: file list", js and any(f["name"] == "test.txt" for f in js["data"]["files"]))

    st, h, raw, js = c.api("config.backups")
    backups = js["data"]["backups"] if js else []
    check("api: automatic backup", len(backups) >= 1, backups)
    if backups:
        name = backups[0]["name"]
        st, h, payload, js = c.call("GET", "config.download", {"name": name}, b"", c.cookie, c.csrf)
        check("api: backup download gzip", payload[:2] == b"\x1f\x8b", (st, payload[:8]))
        st, h, raw, js = c.api("config.restore", "POST", form={"name": name})
        check("api: backup restore", st == 200 and js and js["ok"], (st, raw[:200]))

    st, h, raw, js = c.api("cache.flush", "POST")
    check("api: cache bridge down is explicit", st == 503 and js["error"]["code"] == "bridge", (st, raw[:150]))
    st, h, raw, js = c.api("diag")
    check("api: diagnostics", st == 200 and js and len(js["data"]["checks"]) > 3, st)
    st, h, raw, js = c.api("service", "POST", form={"action": "stop"})
    check("api: service stop", st == 200 and js and js["ok"], (st, raw[:200]))
    st, h, raw, js = c.api("logout", "POST")
    check("api: logout", st == 200, st)
    st, h, raw, js = c.api("status")
    check("api: unauthorized after logout", st == 401, st)


def test_http(inst):
    port = free_port()
    env = base_env(inst["prefix"])
    www = str(inst["lib"] / "www").replace("\\", "/")
    proc = subprocess.Popen([BUSYBOX, "httpd", "-f", "-p", f"127.0.0.1:{port}", "-h", www],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    try:
        ok = False
        for _ in range(40):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                ok = True
                break
            except OSError:
                time.sleep(0.2)
        check("http: httpd listens", ok)
        if not ok:
            return
        base = f"http://127.0.0.1:{port}"
        cookie = ""
        csrf = ""

        def req(method, path, body=None, ctype=None, use_csrf=True, ck=""):
            data = body.encode() if isinstance(body, str) else body
            h = {}
            if ck:
                h["Cookie"] = ck
            if csrf and use_csrf and method != "GET":
                h["X-FSD-CSRF"] = csrf
            if ctype:
                h["Content-Type"] = ctype
            r = urllib.request.Request(base + path, data=data, method=method, headers=h)
            try:
                with urllib.request.urlopen(r, timeout=30) as resp:
                    return resp.status, resp.read(), resp.headers.get_all("Set-Cookie") or []
            except urllib.error.HTTPError as e:
                return e.code, e.read(), e.headers.get_all("Set-Cookie") or []

        def api(action, method="GET", form=None, raw=None, params=""):
            body = None
            ctype = None
            if form is not None:
                body = urllib.parse.urlencode(form)
                ctype = "application/x-www-form-urlencoded"
            elif raw is not None:
                body = raw
                ctype = "text/plain"
            st, payload, cookies = req(method, f"/cgi-bin/api.cgi?action={action}{params}", body, ctype, True, cookie)
            try:
                js = json.loads(payload.decode())
            except Exception:
                js = None
            return st, payload, js, cookies

        st, payload, js, cookies = api("session")
        check("http: session", st == 200 and js and js["data"]["setup_required"], (st, payload[:120]))
        st, payload, js, cookies = api("setup", "POST", form={"token": "setup-token-test", "password": "HttpPass123!"})
        check("http: setup", st == 200 and js and js["ok"], (st, payload[:160]))
        for s in cookies:
            if s.startswith("fsd_session="):
                cookie = s.split(";", 1)[0]
        csrf = js["data"]["csrf"] if js else ""
        st, payload, js, cookies = api("status")
        check("http: status", st == 200 and js and js["ok"], st)
        st, payload, js, cookies = api("config.block", "POST", raw="server 9.9.9.9\n", params="&name=upstreams")
        check("http: apply", st == 200 and js and js["ok"], (st, payload[:200]))
        st, payload, cookies = req("POST", "/cgi-bin/api.cgi?action=config.block&name=upstreams", "server 8.8.8.8\n",
                                   "text/plain", False, cookie)
        check("http: csrf enforced", st == 403, st)
        st, payload, cookies = req("GET", "/cgi-bin/api.cgi?action=config.block&name=upstreams", None,
                                   None, False, cookie)
        check("http: mutating action requires POST", st == 405, st)
        st, payload, cookies = req("GET", "/index.html")
        check("http: static index", st == 200 and b"forksmartdns" in payload, st)
        st, payload, cookies = req("GET", "/../etc/forksmartdns/forksmartdns.conf")
        check("http: traversal blocked", st in (400, 403, 404), st)
        st, payload, js, cookies = api("logout", "POST")
        check("http: logout", st == 200, st)
        st, payload, js, cookies = api("status")
        check("http: unauthorized after logout", st == 401, st)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_fork_core():
    """Install the fork hrdns binary from a local feed with a real SHA-256 check."""
    root = WORK / "forkcore"
    if root.exists():
        shutil.rmtree(root)
    prefix = root / "opt"
    (prefix / "etc").mkdir(parents=True)
    (prefix / "var").mkdir(parents=True)
    (WORK / "tmp").mkdir(parents=True, exist_ok=True)
    feed = root / "feed"
    (feed / "bin" / "aarch64-k3.10").mkdir(parents=True)
    fake = feed / "bin" / "aarch64-k3.10" / "hrdns"
    fake.write_text("#!/bin/sh\n"
                    "if [ \"${1:-}\" = \"-v\" ]; then echo 'hrdns 1.0.0-fake'; exit 0; fi\n"
                    "echo 'hrdns starting...(fake fork core)'\n"
                    "i=0; while [ $i -lt 5 ]; do i=$((i+1)); sleep 1; done\n", encoding="utf-8")
    fake.chmod(0o755)
    (feed / "SHA256SUMS").write_text(
        hashlib.sha256(fake.read_bytes()).hexdigest() + "  bin/aarch64-k3.10/hrdns\n", encoding="utf-8")
    httpd = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), partial(http.server.SimpleHTTPRequestHandler, directory=str(feed)))
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        env = base_env(prefix)
        env["FORKSMDNS_ALLOW_NONROOT"] = "1"
        env["FORKSMDNS_FORK_CORE_URL_BASE"] = f"http://127.0.0.1:{port}"
        args = [PROJECT / "install.sh", "--source", str(PROJECT).replace("\\", "/"), "--prefix",
                str(prefix).replace("\\", "/"), "--no-deps", "--no-start", "--no-autostart",
                "--web-server", "busybox", "--fork-arch", "aarch64-k3.10",
                "--ui-port", str(free_port()), "--dns-port", str(free_port())]
        p = subprocess.run([BUSYBOX, "ash"] + [str(a) for a in args], capture_output=True,
                           text=True, env=env, cwd=str(root), timeout=240)
        inst = prefix / "etc" / "forksmartdns" / "instance.env"
        core = prefix / "etc" / "forksmartdns" / "bin" / "core"
        text = inst.read_text(encoding="utf-8") if inst.is_file() else ""
        check("fork core: download+verify+install", p.returncode == 0, (p.returncode, p.stderr[-800:]))
        check("fork core: binary installed", core.is_file())
        check("fork core: source recorded", "FSD_CORE_SOURCE='fork'" in text and "1.0.0-fake" in text, text)
    finally:
        httpd.shutdown()


def test_install():
    root = WORK / "instroot"
    if root.exists():
        shutil.rmtree(root)
    prefix = root / "opt"
    (prefix / "etc").mkdir(parents=True)
    (prefix / "var").mkdir(parents=True)
    (WORK / "tmp").mkdir(parents=True, exist_ok=True)
    fake = root / "fake-core"
    fake.write_text("#!/bin/sh\n"
                    "if [ \"${1:-}\" = \"-v\" ]; then echo 'hrdns 1.2.3-test'; exit 0; fi\n"
                    "echo 'hrdns starting...'\n"
                    "i=0; while [ $i -lt 5 ]; do i=$((i+1)); sleep 1; done\n", encoding="utf-8")
    fake.chmod(0o755)
    env = base_env(prefix)
    env["FORKSMDNS_ALLOW_NONROOT"] = "1"

    def run(args):
        return subprocess.run([BUSYBOX, "ash"] + [str(a) for a in args], capture_output=True,
                              text=True, env=env, cwd=str(root), timeout=240)

    ui = free_port()
    dns = free_port()
    args = [PROJECT / "install.sh", "--source", str(PROJECT).replace("\\", "/"), "--prefix",
            str(prefix).replace("\\", "/"), "--no-deps", "--no-start", "--no-autostart",
            "--web-server", "busybox", "--core", str(fake).replace("\\", "/"),
            "--ui-port", str(ui), "--dns-port", str(dns)]
    p = run(args)
    check("install: success", p.returncode == 0, (p.returncode, p.stderr[-800:]))
    etc = prefix / "etc" / "forksmartdns"
    conf = etc / "forksmartdns.conf"
    check("install: config", conf.is_file() and f"bind 0.0.0.0:{dns}" in conf.read_text(encoding="utf-8"))
    check("install: setup token", (etc / "setup-token").is_file())
    check("install: api", (prefix / "share" / "forksmartdns" / "www" / "cgi-bin" / "api.cgi").is_file())
    check("install: init", (prefix / "etc" / "init.d" / "forksmartdns").is_file())
    p = run(args)
    check("install: reinstall refused", p.returncode != 0, p.returncode)
    conf.write_text(conf.read_text(encoding="utf-8") + "\n# marker\n", encoding="utf-8")
    p = run(args + ["--upgrade"])
    check("install: upgrade", p.returncode == 0 and "# marker" in conf.read_text(encoding="utf-8"),
          (p.returncode, p.stderr[-500:]))
    p = run([PROJECT / "uninstall.sh", "--prefix", str(prefix).replace("\\", "/")])
    check("uninstall: success", p.returncode == 0, (p.returncode, p.stderr[-500:]))
    check("uninstall: removed", not etc.exists() and not (prefix / "share" / "forksmartdns").exists())


def main():
    if not BUSYBOX:
        print("BUSYBOX not found; set BUSYBOX=/path/to/busybox", file=sys.stderr)
        return 2
    (WORK / "tmp").mkdir(parents=True, exist_ok=True)
    setup_applets()
    inst = build_instance(WORK / "instance")
    test_api(inst)
    test_http(build_instance(WORK / "http-instance"))
    test_fork_core()
    test_install()
    print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
