#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Verifies the conversation-reveal bridge in QuotaStrip: payload shape, reply
acceptance, redirect refusal and the POST itself against an in-process mock.
No real DSH is contacted and no credential is read.
"""
import json
import pathlib
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


def check(condition: bool, name: str) -> None:
    if not condition:
        print(f"FAIL: {name}")
        raise SystemExit(1)


HARNESS = r"""
import Foundation

func emit(_ value: String) { print(value) }

DSHOpenSession.overrideOrigins = [URL(string: "http://127.0.0.1:PORT")!]

let body = DSHOpenSession.body(sessionId: "1c897bf1-c12d-45d1-92d0-2bb77ed16f07")
emit("body=" + String(data: body ?? Data(), encoding: .utf8)!)
emit("blank=" + String(DSHOpenSession.body(sessionId: "   ") == nil))
emit("long=" + String(DSHOpenSession.body(sessionId: String(repeating: "a", count: 4096)) == nil))
emit("ok=" + String(DSHOpenSession.accepted(Data(#"{"ok":true,"pending":{"id":"x","at":1}}"#.utf8))))
emit("notok=" + String(DSHOpenSession.accepted(Data(#"{"ok":false,"error":"bad-json"}"#.utf8))))
emit("garbage=" + String(DSHOpenSession.accepted(Data("not json".utf8))))
emit("empty=" + String(DSHOpenSession.accepted(Data())))

// The bridge hops to the main queue, so this harness must pump the main run loop
// rather than block it on a semaphore.
var failure: String? = "no completion"
var finished = false
DSHOpenSession.request(sessionId: "1c897bf1-c12d-45d1-92d0-2bb77ed16f07") { reason in
    failure = reason
    finished = true
}
let deadline = Date().addingTimeInterval(8)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
emit("completion=" + (failure ?? "nil"))
"""


class Mock(BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):  # noqa: N802 - http.server API
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length)
        Mock.seen.append((self.path, self.headers.get("Content-Type"), body))
        payload = json.dumps({"ok": True, "pending": {"id": "x", "at": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # keep the test output clean
        pass


def main() -> None:
    server = HTTPServer(("127.0.0.1", 0), Mock)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        source = HARNESS.replace("PORT", str(port))
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            harness = tmp_path / "main.swift"
            harness.write_text(source)
            binary = tmp_path / "harness"
            built = subprocess.run(
                [*SWIFTC_CMD, str(SOURCES / "DSHOpenSession.swift"),
                 str(SOURCES / "DSHBalanceProvider.swift"), str(harness), "-o", str(binary)],
                capture_output=True, text=True,
            )
            if built.returncode != 0:
                print(built.stderr)
                raise SystemExit(1)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
    finally:
        server.shutdown()

    out = dict(line.split("=", 1) for line in result.stdout.strip().splitlines() if "=" in line)
    check(json.loads(out["body"]) == {"id": "1c897bf1-c12d-45d1-92d0-2bb77ed16f07"}, "request body carries the conversation id")
    check(out["blank"] == "true", "blank id is refused")
    check(out["long"] == "true", "oversized id is refused")
    check(out["ok"] == "true", "success reply is accepted")
    check(out["notok"] == "false", "error reply is rejected")
    check(out["garbage"] == "false", "non-JSON reply is rejected")
    check(out["empty"] == "false", "empty reply is rejected")
    check(out["completion"] == "nil", "successful POST completes without a message")

    check(len(Mock.seen) == 1, "exactly one POST reached the host")
    path, content_type, body = Mock.seen[0]
    check(path == "/api/usage-stats/open-session", f"POST target path ({path})")
    check(content_type == "application/json", f"POST content type ({content_type})")
    check(json.loads(body) == {"id": "1c897bf1-c12d-45d1-92d0-2bb77ed16f07"}, "host receives the same id")

    print("PASS: open-session bridge checks")


if __name__ == "__main__":
    main()