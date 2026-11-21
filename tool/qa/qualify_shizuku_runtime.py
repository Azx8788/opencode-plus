#!/usr/bin/env python3
"""Qualify the installed OpenCode 2.1.1 plugin API with local model/native fixtures.

Never calls a real model account or Android command. All servers and data are
isolated; the OpenCode process, HTTP fixture and Unix socket are closed on exit.
"""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import re
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="opencode2")
    parser.add_argument("--temp-root", default="/tmp/opencode")
    scenarios = parser.add_mutually_exclusive_group()
    scenarios.add_argument("--mixed", action="store_true", help="Also test a same-step native confirmation wait alongside a direct read")
    scenarios.add_argument("--reject-with-feedback", action="store_true", help="Check that Core delivers an explicit rejection to the model without submitting a native command")
    args = parser.parse_args()
    version = subprocess.check_output([args.binary, "--version"], text=True).strip()
    if version != "opencode v2.1.1":
        raise RuntimeError("This qualification is pinned to OpenCode 2.1.1")
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]
    base = Path(tempfile.mkdtemp(prefix="shizuku-runtime-", dir=args.temp_root))
    for name in ("home", "config/opencode", "data/opencode", "cache", "state", "plugin", "project"):
        (base / name).mkdir(parents=True, exist_ok=True)
    sock = str(base / "native.sock")
    descriptor = {"protocolVersion": 1, "socketPath": sock,
                  "runtimeId": "11111111-1111-1111-1111-111111111111",
                  "bridgeInstance": "22222222-2222-2222-2222-222222222222"}
    description_file = base / "descriptor.json"
    description_file.write_text(json.dumps(descriptor))
    records, native_requests, model_outputs, offered_tools, polls = {}, [], [], [], {}
    commands = ["getprop ro.build.version.release"]
    if args.mixed:
        commands.append("settings put global shizuku_fixture_only 1")

    class NativeFixture(socketserver.BaseRequestHandler):
        def handle(self):
            def read(count):
                value = bytearray()
                while len(value) < count:
                    chunk = self.request.recv(count - len(value))
                    if not chunk:
                        raise RuntimeError("Incomplete native fixture frame")
                    value.extend(chunk)
                return value
            count = struct.unpack(">I", read(4))[0]
            if not 1 <= count <= 131072:
                return
            request = json.loads(read(count))
            native_requests.append(request)
            result = dict(descriptor)
            result.update(environment="android", fallback=False)
            method = request["method"]
            operation = request.get("operationId")
            if method == "prepare":
                result.update(executionReady=True, uid=2000, backend="adb", serviceInstance="fixture-service",
                              brokerInstance="fixture-broker", risk="green" if request["command"] == commands[0] else "red",
                              operationType="read_only" if request["command"] == commands[0] else "write_fixture", automatic=request["command"] == commands[0])
            elif method == "submit":
                if request["command"] not in commands:
                    raise RuntimeError("The model's bare command was changed")
                if operation in records:
                    raise RuntimeError("An operation was submitted twice")
                records[operation] = {"operationId": operation, "state": "succeeded", "uid": 2000, "backend": "adb",
                                      "serviceInstance": "fixture-service", "stdout": "ANDROID_VERSION_FIXTURE",
                                      "stderr": "", "exitCode": 0, "elapsedMs": 7, "termination": "not_requested"}
                if request["command"] != commands[0]:
                    records[operation].update(state="waiting", stdout="CONFIRMATION_FIXTURE")
                    records[operation].pop("exitCode")
                    records[operation].pop("elapsedMs")
                    polls[operation] = 0
                result.update(records[operation])
            elif method in ("lookup", "result"):
                if method == "result" and operation in polls:
                    polls[operation] += 1
                    if polls[operation] >= 2:
                        records[operation].update(state="succeeded", exitCode=0, elapsedMs=7)
                result.update(records.get(operation, {"error": "operation_not_found", "state": "not_executed"}))
            elif method == "cancel":
                result.update(operationId=operation, state="cancelled")
            else:
                result.update(executionReady=True, uid=2000)
            payload = json.dumps(result).encode()
            self.request.sendall(struct.pack(">I", len(payload)) + payload)

    class ModelFixture(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            size = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(size))
            names = [tool.get("function", {}).get("name", "") for tool in body.get("tools", [])]
            target = next((name for name in names if name.endswith("shizuku_exec")), None)
            offered_tools.extend(names)
            outputs = [message for message in body.get("messages", []) if message.get("role") == "tool"]
            if outputs:
                model_outputs.extend(outputs)
            invoke = target is not None and not outputs
            calls = [{"id": f"fixture-native-call-{index}", "type": "function",
                      "function": {"name": target, "arguments": json.dumps({"command": command})}}
                     for index, command in enumerate(commands)]
            message = {"role": "assistant", "content": None, "tool_calls": calls} if invoke else {
                "role": "assistant", "content": "Local fixture finished"}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if body.get("stream") else "application/json")
            self.end_headers()
            if body.get("stream"):
                delta = {"role": "assistant", "tool_calls": [{"index": index, **call} for index, call in enumerate(calls)]} if invoke else {
                    "role": "assistant", "content": "Local fixture finished"}
                for value in (
                    {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture",
                     "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                    {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture",
                     "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls" if invoke else "stop"}]},
                ):
                    self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
                self.wfile.write(b"data: [DONE]\n\n")
            else:
                self.wfile.write(json.dumps({"id": "chatcmpl-fixture", "object": "chat.completion", "created": 1,
                    "model": "fixture", "choices": [{"index": 0, "message": message,
                    "finish_reason": "tool_calls" if invoke else "stop"}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode())

    native = socketserver.ThreadingUnixStreamServer(sock, NativeFixture)
    native.daemon_threads = True
    model = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ModelFixture)
    model.daemon_threads = True
    servers = (native, model)
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    for source, target in (("shizuku_bridge_js.dart", "bridge.js"), ("shizuku_plugin_js.dart", "index.js")):
        text = (repo / "lib/builtin/shizuku" / source).read_text()
        content = re.search(r"r'''(.*)''';", text, re.S).group(1)
        if target == "bridge.js":
            content = content.replace("/root/.oc-builtin/shizuku-bridge.json", str(description_file)).replace("/tmp/.oc-shizuku/s", sock)
        else:
            content = "import { Rpc } from '@opencode/plugin/rpc';\n" + content
            content = content.replace("return () => registration.dispose();", """
  const contract = Rpc.define({id:'qa-shizuku',methods:{tools:{input:{type:'object',properties:{}},output:{type:'object',properties:{ids:{type:'array',items:{type:'string'}}},required:['ids']}}},events:{}});
  const qa = await ctx.rpc.register(contract,{tools:async()=>({ids:(await ctx.tool.list()).filter(t=>t.id.includes('shizuku')).map(t=>t.id)})});
  return async()=>{await qa.dispose();await registration.dispose();};
""")
        (base / "plugin" / target).write_text(content)
    (base / "plugin/package.json").write_text(json.dumps({"name": "shizuku-local-qualification", "version": "1.0.0",
        "type": "module", "exports": {".": "./index.js"}, "dependencies": {"@opencode/plugin": "2.1.1"}}))
    (base / "config/opencode/opencode.json").write_text(json.dumps({"plugins": [str(base / "plugin")],
        "model": "fixture/native-tools", "providers": {"fixture": {"name": "Local test fixture", "env": ["SHIZUKU_FIXTURE_KEY"],
        "package": "@opencode/ai/providers/openai-compatible", "settings": {"baseURL": f"http://127.0.0.1:{model.server_port}/v1"},
        "models": {"native-tools": {"name": "Local tool fixture", "capabilities": {"tools": True}}}}}}))
    env = os.environ.copy()
    for name in list(env):
        if name.startswith("OPENCODE_") or name.endswith("_API_KEY") or name.endswith("_TOKEN"):
            env.pop(name)
    env.update(HOME=str(base / "home"), XDG_CONFIG_HOME=str(base / "config"), XDG_DATA_HOME=str(base / "data"),
               XDG_CACHE_HOME=str(base / "cache"), XDG_STATE_HOME=str(base / "state"),
               OPENCODE_CONFIG_DIR=str(base / "config/opencode"), OPENCODE_DB=str(base / "data/opencode/fixture.db"),
               SHIZUKU_FIXTURE_KEY="fixture-not-a-real-credential")
    # Reserve an available loopback port, without touching a running user's server.
    import socket
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    root = f"http://127.0.0.1:{port}"
    authorization = None

    def request(path, body=None, method=None, timeout=30):
        headers = {"Content-Type": "application/json"}
        if authorization:
            headers["Authorization"] = authorization
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(root + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw) if raw else None

    process = None
    log_path = base / "server.log"
    try:
        with log_path.open("w") as log:
            process = subprocess.Popen([args.binary, "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                       cwd=base / "project", env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 100
            while True:
                if process.poll() is not None:
                    raise RuntimeError("The isolated qualification server exited; inspect the private fixture log")
                try:
                    request("/api/info")
                    break
                except (urllib.error.URLError, TimeoutError):
                    match = re.search(r"^server password (\S+)", log_path.read_text(), re.M)
                    if match:
                        authorization = "Basic " + base64.b64encode(("opencode:" + match.group(1)).encode()).decode()
                    if time.monotonic() > deadline:
                        raise RuntimeError("The isolated qualification server was not ready")
                    time.sleep(.3)
            location = "?" + urllib.parse.urlencode({"location[directory]": str(base / "project")})
            catalog = request("/api/rpc/qa-shizuku/tools" + location, {"input": {}})["output"]["ids"]
            if sorted(catalog) != ["shizuku_exec", "shizuku_result", "shizuku_status"]:
                raise RuntimeError("The actual tool registration does not match the pinned contract")
            session_input = {"title": "Local Android tool fixture"}
            if args.reject_with_feedback:
                session_input["permissions"] = [{"action": "shizuku", "resource": "*", "effect": "ask"}]
            session = request("/api/session" + location, session_input)["data"]["id"]
            request("/api/session/" + session + "/prompt", {"text": "Execute the local contract fixture.", "resume": True})
            if args.reject_with_feedback:
                permission_path = f"/api/session/{session}/permission"
                deadline = time.monotonic() + 30
                while True:
                    pending = request(permission_path)["data"]
                    permission = next((p for p in pending if p["action"] == "shizuku"), None)
                    if permission is not None:
                        break
                    if time.monotonic() > deadline:
                        raise RuntimeError("The fixture command never requested Shizuku approval")
                    time.sleep(.1)
                feedback = "The user declined this Android shell request. Do not retry it."
                request(f"{permission_path}/{permission['id']}/reply", {"decision": "reject", "message": feedback})
            specification = request("/openapi.json")
            wait_path = next((p for p in specification["paths"] if p.endswith("/wait") and "session" in p), None)
            if wait_path:
                path = re.sub(r"\{[^}]+\}", session, wait_path)
                method = next(m for m in specification["paths"][wait_path] if m in ("post", "get"))
                request(path, {} if method == "post" else None, method.upper(), timeout=90)
            else:
                deadline = time.monotonic() + 45
                while not model_outputs and time.monotonic() < deadline:
                    time.sleep(.1)
            submits = [r for r in native_requests if r["method"] == "submit"]
            if args.reject_with_feedback:
                if submits or records:
                    raise RuntimeError("The rejected Shizuku command reached native submit")
                if not any(m.get("tool_call_id") == "fixture-native-call-0" and
                           feedback in json.dumps(m.get("content")) for m in model_outputs):
                    raise RuntimeError("The model did not receive feedback for the rejected call")
                print("Real OpenCode 2.1.1: explicit rejection reached the original tool call in the model input; zero native submits")
                return
            if not model_outputs or not records:
                raise RuntimeError("No model tool-output continuation arrived; inspect the private fixture log")
            returned = json.dumps(model_outputs)
            if "ANDROID_VERSION_FIXTURE" not in returned:
                raise RuntimeError("The actual model continuation lost the native output")
            if len(submits) != len(commands):
                raise RuntimeError("The fixture command did not execute exactly once")
            scope = submits[0]["scope"]
            if scope["sessionID"] != session or scope["directory"] != str(base / "project") or scope["agentID"] != "build" or not scope["messageID"] or not scope["callID"]:
                raise RuntimeError("The actual tool caller scope was lost")
            if args.mixed and ("CONFIRMATION_FIXTURE" not in returned or any(value["state"] != "succeeded" for value in records.values())):
                raise RuntimeError("The mixed direct-read/confirmation fixture did not finish both tool calls")
            print("Real OpenCode 2.1.1 registration → model tool call → private byte bridge → model result continuation: passed")
            if args.mixed:
                print("Same-step direct read + native confirmation waiting: both tools finished and the model continued")
            print("Bare command and Core-provided session/message/call/agent/location identity: passed")
            print("Native and model responses were isolated fixtures. Android privileges were NOT verified.")
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for server in servers:
            server.shutdown()
            server.server_close()
        print("Private qualification artifacts:", base)


if __name__ == "__main__":
    main()
