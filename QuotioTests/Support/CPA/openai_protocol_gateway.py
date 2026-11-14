"""仅用假密钥与 loopback 验证实际 CPA 二进制；禁止真实凭据目录及外网访问。"""
import http.server
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

records = []
patch = json.loads(pathlib.Path(sys.argv[2]).read_text())
groups = patch["api-keys"]
family = "codex" if groups.get("codex") else "openai-compatibility"
expected_path = "/v1/responses" if family == "codex" else "/deployment/v1/chat/completions"


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        # 仅输出协议字段与假工具名称，不记录真实认证头或客户端提示词。
        records.append({"path": self.path, "model": body.get("model"),
                        "has_legacy_limit": "max_tokens" in body,
                        "max_output_tokens": body.get("max_output_tokens"),
                        "max_tokens": body.get("max_tokens"),
                        "max_completion_tokens": body.get("max_completion_tokens"),
                        "reasoning": body.get("reasoning"), "tools": body.get("tools", []),
                        "reasoning_effort": body.get("reasoning_effort"),
                        "tool_choice": body.get("tool_choice"), "parallel_tool_calls": body.get("parallel_tool_calls"),
                        "uses_fixture_key": self.headers.get("Authorization") == "Bearer fixture-upstream"})
        if self.path != expected_path or (family == "codex" and "max_tokens" in body):
            data = json.dumps({"error": {"type": "invalid_request_error", "message": "Wrong OpenAI protocol or max_tokens"}}).encode()
            self.send_response(400)
        elif family == "codex":
            response = {"id": "resp_fixture", "object": "response", "status": "completed", "model": body["model"],
                        "output": [{"id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed",
                                    "content": [{"type": "output_text", "text": "fixture-ok", "annotations": []}]}],
                        "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
            events = [{"type": "response.created", "response": dict(response, status="in_progress", output=[])},
                      {"type": "response.output_text.delta", "item_id": "msg_fixture", "output_index": 0,
                       "content_index": 0, "delta": "fixture-ok"},
                      {"type": "response.completed", "response": response}]
            data = "".join("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n" for event in events).encode()
            self.send_response(200)
        else:
            if body.get("stream"):
                chunk = {"id": "chat_fixture", "object": "chat.completion.chunk", "model": body["model"],
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": "fixture-ok"}, "finish_reason": None}]}
                end = dict(chunk, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}],
                           usage={"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2})
                data = ("data: " + json.dumps(chunk) + "\n\ndata: " + json.dumps(end) + "\n\ndata: [DONE]\n\n").encode()
            else:
                data = json.dumps({"id": "chat_fixture", "object": "chat.completion", "model": body["model"],
                                   "choices": [{"index": 0, "message": {"role": "assistant", "content": "fixture-ok"}, "finish_reason": "stop"}],
                                   "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if family == "codex" or body.get("stream") else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


binary = sys.argv[1]
assert not groups.get("openai-compatibility" if family == "codex" else "codex"), "夹具不允许混入其它通道"
assert all(key["api-key"] == "fixture-upstream" for group in groups[family] for key in group["keys"])
gateway = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
threading.Thread(target=gateway.serve_forever, daemon=True).start()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
results = []
try:
    with tempfile.TemporaryDirectory(prefix="quotio-openai-runtime-") as raw:
        root = pathlib.Path(raw)
        with socket.socket() as port_socket:
            port_socket.bind(("127.0.0.1", 0))
            port = port_socket.getsockname()[1]
        for group in groups[family]:
            # 只替换测试传输地址，凭据族、模型别名、请求头、权重均来自被测生产补丁。
            assert group["base-url"] in ["https://api.openai.com/v1", "https://third-party.invalid/deployment/v1"]
            prefix = "/v1" if family == "codex" else "/deployment/v1"
            group["base-url"] = "http://127.0.0.1:%d%s" % (gateway.server_port, prefix)
        (root / "auth").mkdir()
        config = {"config-version": 8, "server": {"host": "127.0.0.1", "port": port},
                  "management": {"secret-key": "fixture-management", "disable-control-panel": True},
                  "access": {"api-keys": ["fixture-client"]}, "oauth": {"auth-dir": str(root / "auth")}, "api-keys": groups}
        # 迁移后的别名推理规则来自同一份生产 PATCH，不能在夹具里人工修正 effort 掩盖遗漏。
        config["requests"] = patch.get("requests", {})
        config_file = root / "config.json"
        config_file.write_text(json.dumps(config))
        # CPA 使用本地模型目录，出站只有本地假网关可用；额外拒绝真实账号和钥匙串文件读取。
        profile = '(version 1) (allow default) (deny network-outbound) (allow network-outbound (remote ip "localhost:*"))'
        for protected in [".cli-proxy-api", ".claude", "Library/Keychains"]:
            profile += ' (deny file-read* (subpath %s))' % json.dumps(str(pathlib.Path.home() / protected))
        with (root / "runtime.log").open("w") as log:
            process = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, binary,
                                        "-config", str(config_file), "--local-model"], cwd=root, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    try:
                        opener.open("http://127.0.0.1:%d/" % port, timeout=.2)
                        break
                    except urllib.error.HTTPError:
                        break
                    except OSError:
                        time.sleep(.1)
                schema = {"type": "object", "properties": {"value": {"type": "string"}}}
                tool = {"name": "fixture_tool", "description": "fixture", "parameters": schema}
                cases = [("messages", {"max_tokens": 65536,
                                      "messages": [{"role": "user", "content": "fixture only"}],
                                      "tools": [{"name": "fixture_tool", "description": "fixture", "input_schema": schema}],
                                      "tool_choice": {"type": "tool", "name": "fixture_tool", "disable_parallel_tool_use": True}}),
                         ("chat/completions", {"max_completion_tokens": 1234, "reasoning_effort": "xhigh",
                                               "messages": [{"role": "user", "content": "fixture only"}],
                                               "tools": [{"type": "function", "function": tool}],
                                               "tool_choice": {"type": "function", "function": {"name": "fixture_tool"}},
                                               "parallel_tool_calls": False})]
                if family == "codex":
                    cases.append(("responses", {"max_output_tokens": 4321, "input": "fixture only",
                                                "reasoning": {"effort": "xhigh"}, "tools": [dict(tool, type="function")],
                                                "tool_choice": {"type": "function", "name": "fixture_tool"}, "parallel_tool_calls": False}))
                for endpoint, source in cases:
                    for streaming in [False, True]:
                        # Messages 故意不传 effort，仅依赖生产迁移生成的旧 alias 规则。
                        payload = dict(source, model="fixture-route", stream=streaming)
                        request = urllib.request.Request("http://127.0.0.1:%d/v1/%s" % (port, endpoint),
                                                         json.dumps(payload).encode(), {"Content-Type": "application/json",
                                                         "x-api-key": "fixture-client", "anthropic-version": "2023-06-01"})
                        with opener.open(request, timeout=10) as response:
                            data = response.read().decode()
                            results.append({"status": response.status, "source": endpoint, "stream": streaming, "content_ok": "fixture-ok" in data})
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
finally:
    gateway.shutdown()
print(json.dumps({"results": results, "requests": records}))
