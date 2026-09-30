#!/usr/bin/env python3
"""Stage 15B: one capabilities request and JSON Lines response."""

import json
import re
import sys

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
    if not isinstance(value, dict) or set(value) != {
        "protocol_version", "operation_id", "operation"
    }:
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
        if value["operation"] != "capabilities":
            emit(1, "failed", operation_id, {"code": "unsupported_operation"})
            return 2
    except (ValueError, UnicodeError, json.JSONDecodeError):
        emit(1, "failed", operation_id, {"code": "invalid_request"})
        return 2

    emit(1, "started", operation_id)
    emit(2, "result", operation_id, {
        "protocol_version": PROTOCOL_VERSION,
        "product_version": version,
        "operations": ["capabilities"],
    })
    emit(3, "completed", operation_id)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
