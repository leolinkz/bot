#!/usr/bin/env python3
"""
fx-trade-scout — desktop app.

Wraps agent.py in a native window (pywebview). If pywebview isn't installed, a
stdlib browser fallback serves the same UI:  python3 desktop_app.py --web

  pip install -r requirements-desktop.txt
  python3 desktop_app.py            # native window
  python3 desktop_app.py --web      # browser fallback (no extra deps)
"""
import os, sys, json, pathlib

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import agent  # noqa: E402

CONFIG = HERE / "config.env"
UI = HERE / "ui" / "index.html"
KEYS = ["LLM_BASE_URL", "LLM_MODEL", "LLM_API_KEY", "LLM_TEMPERATURE", "DERIV_APP_ID", "SYMBOL", "MIN_RR"]
DEFAULTS = {"LLM_BASE_URL": "http://localhost:11434/v1", "LLM_MODEL": "llama3.1:8b",
            "LLM_API_KEY": "ollama", "LLM_TEMPERATURE": "0.2", "DERIV_APP_ID": "1089",
            "SYMBOL": "R_75", "MIN_RR": "1.5"}


def read_config():
    cfg = dict(DEFAULTS)
    if CONFIG.exists():
        for line in CONFIG.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


def write_config(cfg):
    lines = ["# fx-trade-scout local config (edited by the desktop app)"]
    lines += [f"{k}={cfg.get(k, DEFAULTS.get(k, ''))}" for k in KEYS]
    CONFIG.write_text("\n".join(lines) + "\n")


def apply_config(cfg):
    for k in KEYS:
        if k in cfg and cfg[k] != "":
            os.environ[k] = str(cfg[k])


class Api:
    def get_state(self, arg=None):
        cfg = read_config()
        log = agent.load_log()
        briefs = sorted(agent.BRIEFS.glob("*.md"))[-12:]
        recent = [{"name": b.name, "md": b.read_text()} for b in reversed(briefs)]
        return {"config": cfg, "track": log.get("track", {}),
                "open_ideas": [i for i in log.get("ideas", []) if i.get("status") == "open"],
                "briefs": recent}

    def save_config(self, arg=None):
        cfg = arg or {}
        merged = {**read_config(), **{k: v for k, v in cfg.items() if k in KEYS}}
        write_config(merged); apply_config(merged)
        return {"ok": True, "config": merged}

    def test(self, arg=None):
        cfg = read_config(); apply_config(cfg)
        out = {"ollama": False, "deriv": False, "detail": ""}
        try:
            import urllib.request
            root = cfg["LLM_BASE_URL"].rstrip("/").replace("/v1", "")
            urllib.request.urlopen(root + "/api/tags", timeout=5)
            out["ollama"] = True
        except Exception as e:
            out["detail"] += f"model server: {e}; "
        try:
            agent.fetch_candles(3600, 2); out["deriv"] = True
        except Exception as e:
            out["detail"] += f"deriv: {e}; "
        return out

    def run_scan(self, arg=None):
        cfg = read_config(); apply_config(cfg)
        try:
            return {"ok": True, **agent.scan()}
        except agent.DataError as e:
            return {"ok": False, "stage": "data", "error": str(e)}
        except agent.LLMError as e:
            return {"ok": False, "stage": "llm", "error": str(e)}
        except Exception as e:
            return {"ok": False, "stage": "other", "error": repr(e)}


def serve_web(port=8765):
    import http.server, socketserver, webbrowser
    api = Api()

    class H(http.server.BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self._send(200, UI.read_text().encode(), "text/html; charset=utf-8")
            else:
                self._send(404, b"{}")

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            try:
                arg = json.loads(self.rfile.read(n) or b"{}") if n else {}
            except Exception:
                arg = {}
            method = self.path.strip("/").split("/")[-1]
            fn = getattr(api, method, None)
            if not callable(fn) or method.startswith("_"):
                self._send(404, b'{"error":"no such method"}'); return
            try:
                res = fn(arg)
            except Exception as e:
                res = {"ok": False, "error": repr(e)}
            self._send(200, json.dumps(res).encode())

        def log_message(self, *a):
            pass

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), H) as httpd:
        url = f"http://127.0.0.1:{port}"
        print(f"fx-trade-scout web UI → {url}  (Ctrl-C to stop)")
        try:
            webbrowser.open(url)
        except Exception:
            pass
        httpd.serve_forever()


def main():
    if "--web" in sys.argv:
        serve_web()
        return
    try:
        import webview
    except ImportError:
        print("pywebview isn't installed.")
        print("  install it:   pip install -r requirements-desktop.txt")
        print("  or run in browser instead:   python3 desktop_app.py --web")
        sys.exit(1)
    webview.create_window("fx-trade-scout", str(UI), js_api=Api(),
                          width=1120, height=800, min_size=(940, 660))
    webview.start()


if __name__ == "__main__":
    main()
