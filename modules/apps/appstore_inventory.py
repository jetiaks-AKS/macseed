"""Validate MAS 7 JSON inventory; emit only IDs for the existing presence consumer."""
import json
import sys


def inventory_ids(text):
    if not text.strip():
        return []
    try:
        value = json.loads(text)
        rows = value if isinstance(value, list) else [value]
    except json.JSONDecodeError:
        rows = []
        for line in text.splitlines():
            if not line.strip():
                continue
            value = json.loads(line)
            rows.extend(value if isinstance(value, list) else [value])
    ids = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('invalid inventory record')
        value = row.get('adamID')
        if type(value) is not int or not 0 < value < 2**64 or value in ids:
            raise ValueError('invalid inventory ID')
        ids.append(value)
    return ids


if __name__ == '__main__':
    try:
        ids = inventory_ids(sys.stdin.read())
    except (ValueError, TypeError):
        sys.exit(2)
    for value in ids:
        print(f'{value} Installed')
