# macOS Discovery

Reads supported preferences without applying them or inventing values for absent
keys. Publishes independently validated category files under
`config/generated/macos/`: `finder.conf`, `dock.conf`, `windows.conf`,
`keyboard.conf`, `trackpad.conf`, `screenshots.conf`.

Records are typed `domain|key|type|value` data. The shared category-aware validator
in `modules/settings/macos/records.sh` rejects invalid keys/types, duplicates and
unsafe scalars before atomic publication. Data is never `source`d or `eval`uated.

Safe unsupported enum values are skipped with warnings while other valid records
publish. Observation/type/scalar/candidate errors return `2` and preserve the
previous category file. Absent source preferences create no record and remain
unmanaged. [Configuration](../../../docs/toolkit/CONFIGURATION.md#macos-settings)
owns the exact key/type lists, enums, Screenshot paths and effect limitations.
