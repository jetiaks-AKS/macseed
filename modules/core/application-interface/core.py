#!/usr/bin/env python3
"""Small JSON Lines adapter for supported Core operations."""

import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bundle"))
import bundle

PROTOCOL_VERSION = 1
MAX_REQUEST = 4096
OPERATION_ID = re.compile(r"[A-Za-z0-9_-]{1,64}\Z", re.ASCII)


def emit(sequence, kind, operation_id, data=None):
    record = {
        "protocol_version": PROTOCOL_VERSION,
        "operation_id": operation_id,
        "sequence": sequence,
        "type": kind,
    }
    if data is not None:
        record["data"] = data
    print(json.dumps(record, ensure_ascii=True, separators=(",", ":")), flush=True)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def request():
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    if not raw or len(raw) > MAX_REQUEST:
        raise ValueError("empty or oversized request")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise ValueError("invalid request shape")
    return value


def main(version):
    operation_id = None
    try:
        value = request()
        candidate = value["operation_id"]
        if not isinstance(candidate, str) or not OPERATION_ID.fullmatch(candidate):
            raise ValueError("invalid operation id")
        operation_id = candidate
        if type(value["protocol_version"]) is not int or value["protocol_version"] != PROTOCOL_VERSION:
            code = "unsupported_protocol" if type(value["protocol_version"]) is int else "invalid_request"
            emit(1, "failed", operation_id, {"code": code})
            return 2
        if not isinstance(value["operation"], str):
            raise ValueError("invalid operation")
        operation = value["operation"]
        required = {"protocol_version", "operation_id", "operation"}
        if operation == "capabilities":
            if set(value) != required:
                raise ValueError("invalid capabilities request")
        elif operation == "bundle_inspect":
            if set(value) != required | {"parameters"}:
                raise ValueError("invalid Bundle request")
            parameters = value["parameters"]
            if not isinstance(parameters, dict) or set(parameters) != {"path"}:
                raise ValueError("invalid Bundle parameters")
            path = parameters["path"]
            if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
                raise ValueError("invalid Bundle path")
        else:
            emit(1, "failed", operation_id, {"code": "unsupported_operation"})
            return 2
    except (KeyError, ValueError, UnicodeError):
        emit(1, "failed", operation_id, {"code": "invalid_request"})
        return 2

    emit(1, "started", operation_id)
    if operation == "capabilities":
        result = {
            "protocol_version": PROTOCOL_VERSION,
            "product_version": version,
            "operations": ["capabilities", "bundle_inspect"],
        }
    else:
        try:
            input_path = Path(path)
            mode = input_path.lstat().st_mode
            if not stat.S_ISREG(mode):
                raise bundle.Invalid("unsafe Bundle input")
            result = bundle.inspect_bundle(input_path, os.environ["HOME"])
        except bundle.Unsupported:
            emit(2, "failed", operation_id, {"code": "unsupported_bundle"})
            return 2
        except (FileNotFoundError, PermissionError):
            emit(2, "failed", operation_id, {"code": "bundle_unavailable"})
            return 2
        except (bundle.Invalid, tarfile.TarError, ValueError, TypeError, KeyError, UnicodeError):
            emit(2, "failed", operation_id, {"code": "bundle_invalid"})
            return 2
        except Exception:
            emit(2, "failed", operation_id, {"code": "internal_error"})
            return 2
    emit(2, "result", operation_id, result)
    emit(3, "completed", operation_id)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
