f() { local -a a; a=("${(@f)$(print x)}"); print -rl -- ${(q)a}; }
