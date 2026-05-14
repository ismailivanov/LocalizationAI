#!/usr/bin/env python3
"""
Localization AI - Model Manager
Manage Ollama models: list, pull, delete.
No external dependencies (stdlib only).
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error


def _api_url(base: str, path: str) -> str:
    return f"{base.rstrip('/')}{path}"


# ── List installed models ─────────────────────────────────────────────────────

def list_models(api_url: str) -> None:
    try:
        req = urllib.request.Request(_api_url(api_url, "/api/tags"))
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        models = []
        for m in data.get("models", []):
            models.append({
                "name": m.get("name", ""),
                "size": int(m.get("size", 0)),  # bytes on disk
            })
        print(json.dumps({"type": "models", "models": models}), flush=True)
    except urllib.error.URLError as e:
        print(json.dumps({"type": "error", "message": f"Cannot reach Ollama: {e.reason}"}), flush=True)
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"type": "error", "message": str(e)}), flush=True)
        sys.exit(1)


# ── Pull (download) a model ───────────────────────────────────────────────────

def _write_progress(path: str, payload: dict) -> None:
    if not path:
        return
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except OSError:
        pass


def pull_model(api_url: str, model: str, progress_file: str = "") -> None:
    payload = json.dumps({"name": model, "stream": True}).encode("utf-8")
    req = urllib.request.Request(
        _api_url(api_url, "/api/pull"),
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            for raw_line in resp:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue

                status = data.get("status", "")
                total     = data.get("total", 0)
                completed = data.get("completed", 0)
                percent   = int(completed / total * 100) if total else 0

                progress_payload = {
                    "type":      "progress",
                    "status":    status,
                    "percent":   percent,
                    "completed": completed,
                    "total":     total,
                }
                print(json.dumps(progress_payload), flush=True)
                _write_progress(progress_file, progress_payload)

                if status == "success":
                    done_payload = {"type": "done", "model": model, "percent": 100}
                    print(json.dumps(done_payload), flush=True)
                    _write_progress(progress_file, done_payload)
                    return

    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        err = {"type": "error", "message": f"HTTP {e.code}: {body}"}
        print(json.dumps(err), flush=True)
        _write_progress(progress_file, err)
        sys.exit(1)
    except urllib.error.URLError as e:
        err = {"type": "error", "message": f"Cannot reach Ollama: {e.reason}"}
        print(json.dumps(err), flush=True)
        _write_progress(progress_file, err)
        sys.exit(1)


# ── Delete a model ────────────────────────────────────────────────────────────

def delete_model(api_url: str, model: str) -> None:
    payload = json.dumps({"name": model}).encode("utf-8")
    req = urllib.request.Request(
        _api_url(api_url, "/api/delete"),
        data=payload,
        headers={"Content-Type": "application/json"},
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as _:
            pass
        print(json.dumps({"type": "done", "model": model}), flush=True)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(json.dumps({"type": "error", "message": f"HTTP {e.code}: {body}"}), flush=True)
        sys.exit(1)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Ollama model manager")
    parser.add_argument("--action",  required=True, choices=["list", "pull", "delete"])
    parser.add_argument("--api-url", default="http://localhost:11434")
    parser.add_argument("--model",   default="")
    parser.add_argument("--progress-file", default="")
    args = parser.parse_args()

    if args.action == "list":
        list_models(args.api_url)
    elif args.action == "pull":
        if not args.model:
            print(json.dumps({"type": "error", "message": "Model name required"}), flush=True)
            sys.exit(1)
        pull_model(args.api_url, args.model, args.progress_file)
    elif args.action == "delete":
        if not args.model:
            print(json.dumps({"type": "error", "message": "Model name required"}), flush=True)
            sys.exit(1)
        delete_model(args.api_url, args.model)


if __name__ == "__main__":
    main()
