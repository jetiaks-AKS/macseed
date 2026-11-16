# Shell parser corpus provenance

The 83 `.zsh` files listed by `manifest.json`, the manifest itself, byte hashes and
golden spans are unchanged copies of the corpus in the 2026-11-15 experiment's
`macseed-parser-a-cbss50d9.evidence.zip`. The original archive was confirmed present
read-only during this checkpoint. It was not modified or deleted.

Archive: 88,904 bytes, SHA-256
`76dea4a892d1f49a6044abd7bb5c649c35835d1d7c60dd5d6e394e0d2d8c0c71`.
Manifest SHA-256:
`a1028f3151de7cbb53ddf772fe77b1fdfdae4bdb3df8ca89d4f0e48e81afd284`.

The archive's `corpus.py` authored 65 valid cases, 15 malformed cases and three
encoding/line-ending probes. Its manifest records byte counts, hashes, expected
ranges and context labels. An unlisted stale `10_multiline_header.zsh` from that
archive is intentionally not part of the manifest or copied corpus. No fixture
was executed with Zsh and no independent Zsh syntax oracle was claimed.

These context labels do not confer Restore eligibility. Anonymous, multiple-name,
nested, alias/options, source and hook examples are structural evidence only.
The helper accepts CRLF as unchanged bytes, rejects NUL/invalid UTF-8 and uses
only the explicitly selected default Zsh grammar.

The focused test reproduces the archive's 570 proper-prefix probes of
`01_braces`, `16_controls`, `20_substitutions`, `23_heredoc_quoted` and
`25_heredoc_queue`. Resource, process, output, suffix-heredoc, packaging and seeded
mutation tests are new implementation evidence, separate from the original corpus.
`faults.c` is test-only and is never linked into the shipping executable.

See the [internal interface](../../../docs/core/SHELL-PARSER.md) for limits and gaps.
