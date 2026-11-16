/* Test-only executable. No fault controls are compiled into the shipped helper. */
#define main production_main
#include "../../../modules/shell/parser/helper.c"
#undef main

const TSLanguage *tree_sitter_zsh(void) { return NULL; }
static int scenario;
static void ready(int signal_number) {
    (void)signal_number;
    (void)write(1, "ready\n", 6);
}
static void fault(int descriptor) {
    if (scenario == 1) {
        (void)write(2, "PRIVATE_ASSERTION_MARKER", sizeof("PRIVATE_ASSERTION_MARKER") - 1);
        raise(SIGABRT);
    }
    if (scenario == 2) for (;;) pause();
    if (scenario == 3) {
        unsigned char bytes[4096] = {0};
        for (;;) if (write(descriptor, bytes, sizeof(bytes)) < 0) _exit(0);
    }
    if (scenario == 4) { (void)write(descriptor, "short", 5); _exit(0); }
    if (scenario == 5) { (void)bounded_malloc(ALLOCATION_LIMIT); _exit(0); }
    if (scenario == 6) { (void)bounded_calloc(SIZE_MAX, 2); _exit(0); }
    if (scenario == 7) {
        void *p = bounded_malloc(ALLOCATION_LIMIT / 2);
        (void)bounded_realloc(p, ALLOCATION_LIMIT / 2);
        _exit(0);
    }
    if (scenario == 8) {
        volatile unsigned char *p = malloc(RSS_LIMIT + 32 * 1024 * 1024);
        if (!p) _exit(INTERNAL);
        for (size_t i = 0; i < RSS_LIMIT + 32 * 1024 * 1024; i += 4096) p[i] = 1;
        for (;;) pause();
    }
    if (scenario == 9) {
        for (size_t i = 0; i <= ALLOCATION_COUNT; i++) bounded_free(bounded_malloc(1));
        _exit(0);
    }
    if (scenario == 10) {
        kill(owner, SIGUSR1);
        for (;;) pause();
    }
    _exit(90); /* Unknown exit must not become an allowlisted reason. */
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct rlimit core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &core)) return 2;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, cancel_handler);
    signal(SIGUSR1, ready);
    scenario = atoi(argv[1]);
    deadline = milliseconds() + 500;
    enum Failure failure = supervise(fault);
    printf("%s\n", codes[failure]);
    errno = 0;
    /* Supervision must leave no waitable/running child. */
    return waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD ? 0 : 3;
}
