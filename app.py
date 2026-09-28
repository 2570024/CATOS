#!/usr/bin/env python3
"""CATOS standalone router.

No Flask or external package is required. Run with:
    python3 app.py

Routing rule:
    A0001 / a0001 -> admin (事務)
    T0001 / t0001 -> faculty (教員)
    0001          -> student (生徒)
"""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import html
import re
import json
from datetime import datetime

ROOT = Path(__file__).resolve().parent
PORT = 8080
REGISTRY = ROOT / "registered_users.json"


def role_from_user_id(user_id: str):
    value = user_id.strip()
    if not value:
        return None, "ユーザーIDを入力してください。"
    if re.match(r"^[Aa]", value):
        return "admin", None
    if re.match(r"^[Tt]", value):
        return "faculty", None
    if re.match(r"^[A-Za-z]", value):
        return None, "先頭は A（事務）または T（教員）、または無印（生徒）にしてください。"
    return "student", None


class CATOSHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def send_bytes(self, data: bytes, content_type: str = "text/html; charset=utf-8", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def serve_path(self, relative: str):
        target = (ROOT / relative).resolve()
        if ROOT not in target.parents and target != ROOT:
            self.send_error(403)
            return
        if not target.is_file():
            self.send_error(404)
            return
        data = target.read_bytes()
        content_type = self.guess_type(str(target))
        if target.suffix == ".js":
            content_type = "text/javascript; charset=utf-8"
        elif target.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        self.send_bytes(data, content_type)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ("/", "/index.html"):
            error = parse_qs(parsed.query).get("error", [""])[0]
            page = (ROOT / "index.html").read_text(encoding="utf-8").replace("{error}", html.escape(error))
            self.send_bytes(page.encode("utf-8"))
            return

        # Role page roots. Assets requested under a role path are mapped to the shared root.
        role_pages = {"/student": "index_student.html", "/teacher": "index_teacher.html", "/admin": "index_admin.html"}
        for prefix, filename in role_pages.items():
            if path == prefix or path == prefix + "/":
                self.serve_path(filename)
                return
            if path.startswith(prefix + "/"):
                self.serve_path(path[len(prefix) + 1:])
                return
        self.serve_path(path.lstrip("/"))

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path not in ("/login", "/register"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        fields = parse_qs(body)
        user_id = fields.get("user_id", [""])[0].strip()
        role, error = role_from_user_id(user_id)
        if parsed.path == "/register" and not error:
            display_name = fields.get("display_name", [""])[0].strip()
            campus = fields.get("campus", ["大阪成蹊大学"])[0]
            if not display_name:
                error = "表示名を入力してください。"
            else:
                records = []
                if REGISTRY.exists():
                    try:
                        records = json.loads(REGISTRY.read_text(encoding="utf-8"))
                    except (json.JSONDecodeError, OSError):
                        records = []
                records = [r for r in records if r.get("user_id", "").lower() != user_id.lower()]
                records.append({"user_id": user_id, "display_name": display_name, "campus": campus, "role": role, "initial_sync": fields.get("sync", [""])[0] == "on", "registered_at": datetime.now().isoformat(timespec="seconds")})
                REGISTRY.write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
        if error:
            location = "/?error=" + html.escape(error, quote=True)
        else:
            location = {"student": "/student/?login=1", "faculty": "/teacher/?login=1", "admin": "/admin/?login=1"}[role]
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def log_message(self, format, *args):
        print("[CATOS]", format % args)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), CATOSHandler)
    print(f"CATOS is running at http://127.0.0.1:{PORT}")
    print("Prefix: A=事務 / T=教員 / 無印=生徒")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nCATOS stopped")
    finally:
        server.server_close()
