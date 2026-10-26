#!/usr/bin/env python3
"""
obsidian_mcp_client.py — MCP client for Obsidian note publishing
Uses stdio JSON-RPC 2.0 to communicate with obsidian-mcp server.

Usage:
    obsidian_mcp_client.py configure <vault_path>
    obsidian_mcp_client.py write <note_path> <content_file>
    obsidian_mcp_client.py write_image <image_path> <vault_attachment_path>
    obsidian_mcp_client.py status
"""

import json
import os
import subprocess
import sys
import time

MCP_SERVER = os.path.expanduser("~/.zcode/venvs/obsidian-mcp/bin/obsidian-mcp")


class ObsidianMCPClient:
    def __init__(self):
        self.proc = None
        self.msg_id = 0

    def start(self):
        self.proc = subprocess.Popen(
            [MCP_SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def stop(self):
        if self.proc:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)

    def send_request(self, method, params=None):
        self.msg_id += 1
        msg = {"jsonrpc": "2.0", "id": self.msg_id, "method": method}
        if params:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

        # Read response
        while True:
            line = self.proc.stdout.readline()
            if not line:
                break
            try:
                resp = json.loads(line)
                if resp.get("id") == self.msg_id:
                    return resp
            except json.JSONDecodeError:
                continue
        return None

    def send_notification(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def initialize(self):
        resp = self.send_request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "meeting-to-obsidian", "version": "1.0"},
            },
        )
        if resp and "result" in resp:
            self.send_notification("notifications/initialized")
            return True
        return False

    def configure(self, vault_path):
        resp = self.send_request(
            "tools/call",
            {
                "name": "obsidian_configure",
                "arguments": {"vault_path": vault_path},
            },
        )
        return resp

    def write_note(self, path, content):
        resp = self.send_request(
            "tools/call",
            {
                "name": "obsidian_write",
                "arguments": {"path": path, "content": content},
            },
        )
        return resp

    def append_note(self, path, content, heading=None):
        args = {"path": path, "content": content}
        if heading:
            args["heading"] = heading
        resp = self.send_request(
            "tools/call", {"name": "obsidian_append", "arguments": args}
        )
        return resp

    def list_notes(self, folder=None, recursive=False):
        args = {}
        if folder:
            args["folder"] = folder
        if recursive:
            args["recursive"] = True
        resp = self.send_request(
            "tools/call", {"name": "obsidian_list", "arguments": args}
        )
        return resp

    def status(self):
        resp = self.send_request(
            "tools/call", {"name": "obsidian_status", "arguments": {}}
        )
        return resp


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    client = ObsidianMCPClient()
    client.start()

    try:
        if not client.initialize():
            print("FAIL: MCP initialization failed", file=sys.stderr)
            sys.exit(1)

        if cmd == "configure":
            vault_path = sys.argv[2]
            resp = client.configure(vault_path)
            print(json.dumps(resp, indent=2, ensure_ascii=False))

        elif cmd == "write":
            note_path = sys.argv[2]
            content_file = sys.argv[3]
            with open(content_file, "r", encoding="utf-8") as f:
                content = f.read()
            resp = client.write_note(note_path, content)
            print(json.dumps(resp, indent=2, ensure_ascii=False))

        elif cmd == "append":
            note_path = sys.argv[2]
            content_file = sys.argv[3]
            heading = sys.argv[4] if len(sys.argv) > 4 else None
            with open(content_file, "r", encoding="utf-8") as f:
                content = f.read()
            resp = client.append_note(note_path, content, heading)
            print(json.dumps(resp, indent=2, ensure_ascii=False))

        elif cmd == "list":
            folder = sys.argv[2] if len(sys.argv) > 2 else None
            recursive = len(sys.argv) > 3 and sys.argv[3] == "--recursive"
            resp = client.list_notes(folder, recursive)
            print(json.dumps(resp, indent=2, ensure_ascii=False))

        elif cmd == "status":
            resp = client.status()
            print(json.dumps(resp, indent=2, ensure_ascii=False))

        else:
            print(f"Unknown command: {cmd}", file=sys.stderr)
            print(__doc__)
            sys.exit(1)

    finally:
        client.stop()


if __name__ == "__main__":
    main()
