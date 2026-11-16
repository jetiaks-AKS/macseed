f() { helper "$@" && fallback || :; }
f | cat
