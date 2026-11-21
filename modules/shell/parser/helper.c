/* Core-owned structural inspection only. Never execute or regenerate Shell. */
#include <tree_sitter/api.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern const TSLanguage *tree_sitter_zsh(void);
enum {
    INPUT_LIMIT = 128 * 1024, DEFINITION_LIMIT = 64 * 1024,
    DEFINITION_COUNT = 512, NAME_COUNT = 16, NODE_LIMIT = 65536,
    TREE_DEPTH = 256, SYNTAX_DEPTH = 32, OUTPUT_LIMIT = 128 * 1024,
    ALLOCATION_LIMIT = 128 * 1024 * 1024, ALLOCATION_COUNT = 1000000,
    RSS_LIMIT = 192 * 1024 * 1024, PARSE_MS = 1000, PROCESS_MS = 2000
};
enum Failure {
    OK, ARGUMENT, INPUT_IO, INPUT_SIZE, ENCODING, SYNTAX, BOUNDARY,
    DEPTH, NODES, DEFINITIONS, DEFINITION_SIZE, NAMES, ALLOCATION,
    OUTPUT, TIMEOUT, CANCELLED, PROCESS, MEMORY, INTERNAL
};
static const char *const codes[] = {
    "ok", "invalid_request", "input_io", "input_limit", "invalid_encoding",
    "syntax_invalid", "boundary_uncertain", "nesting_limit", "node_limit",
    "definition_count_limit", "definition_size_limit", "name_count_limit",
    "allocation_limit", "output_limit", "timeout", "cancelled",
    "process_failed", "memory_limit", "internal_error"
};
typedef struct { uint32_t start, end; } Span;
typedef struct {
    Span unit, body, names[NAME_COUNT];
    uint32_t name_count, depth;
    int32_t parent;
} Definition;
typedef struct {
    uint32_t count, nodes, syntax_depth;
    uint64_t allocation_peak;
    Definition definitions[DEFINITION_COUNT];
    uint32_t statement_count;
    Span statements[DEFINITION_COUNT];
} Result;
static unsigned char source[INPUT_LIMIT + 1];
static uint32_t source_length;
static Result result;
static uint32_t heredoc_redirects[DEFINITION_COUNT], heredoc_bodies[DEFINITION_COUNT];
static volatile sig_atomic_t cancelled;
static int64_t deadline, parse_deadline;
static pid_t owner;

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) _exit(INTERNAL);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void cancel_handler(int signal_number) { (void)signal_number; cancelled = 1; }
static enum Failure interrupted(void) {
    if (cancelled) return CANCELLED;
    return milliseconds() >= deadline ? TIMEOUT : OK;
}
static void worker_fail(enum Failure reason) { _exit(reason); }

/* Include header overhead and transient realloc storage in the hard budget.
 * Returning NULL is unsafe for upstream assert-based allocation callers. */
typedef union { max_align_t alignment; size_t bytes; } Allocation;
static size_t allocated, allocation_peak, allocations;
static void *bounded_malloc(size_t size) {
    if (++allocations > ALLOCATION_COUNT || size > SIZE_MAX - sizeof(Allocation)) worker_fail(ALLOCATION);
    size_t total = size + sizeof(Allocation);
    if (total > ALLOCATION_LIMIT - allocated) worker_fail(ALLOCATION);
    Allocation *block = malloc(total);
    if (!block) worker_fail(ALLOCATION);
    block->bytes = total;
    allocated += total;
    if (allocated > allocation_peak) allocation_peak = allocated;
    return block + 1;
}
static void bounded_free(void *pointer) {
    if (!pointer) return;
    Allocation *block = (Allocation *)pointer - 1;
    allocated -= block->bytes;
    free(block);
}
static void *bounded_calloc(size_t count, size_t size) {
    if (count && size > SIZE_MAX / count) worker_fail(ALLOCATION);
    void *pointer = bounded_malloc(count * size);
    memset(pointer, 0, count * size);
    return pointer;
}
static void *bounded_realloc(void *pointer, size_t size) {
    if (!pointer) return bounded_malloc(size);
    size_t previous = ((Allocation *)pointer - 1)->bytes - sizeof(Allocation);
    void *replacement = bounded_malloc(size);
    memcpy(replacement, pointer, previous < size ? previous : size);
    bounded_free(pointer);
    return replacement;
}

static int utf8_valid(void) {
    for (uint32_t i = 0; i < source_length;) {
        uint32_t c = source[i++], needed, value, minimum;
        if (!c) return 0;
        if (c < 0x80) continue;
        if (c >= 0xc2 && c <= 0xdf) { needed = 1; value = c & 31; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { needed = 2; value = c & 15; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { needed = 3; value = c & 7; minimum = 0x10000; }
        else return 0;
        if (needed > source_length - i) return 0;
        while (needed--) {
            c = source[i++];
            if ((c & 0xc0) != 0x80) return 0;
            value = (value << 6) | (c & 63);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    return 1;
}
static int byte_boundary(uint32_t offset) {
    return offset <= source_length && (offset == source_length || (source[offset] & 0xc0) != 0x80);
}
static Span span(TSNode node) {
    Span value = {ts_node_start_byte(node), ts_node_end_byte(node)};
    if (ts_node_is_null(node) || value.start > value.end ||
        !byte_boundary(value.start) || !byte_boundary(value.end)) worker_fail(BOUNDARY);
    return value;
}
static int contains(Span outer, Span inner) { return outer.start <= inner.start && inner.end <= outer.end; }
static int whitespace(uint32_t start, uint32_t end) {
    for (uint32_t i = start; i < end; i++)
        if (source[i] != ' ' && source[i] != '\t' && source[i] != '\r' && source[i] != '\n') return 0;
    return 1;
}
static const char *read_source(void *payload, uint32_t offset, TSPoint position, uint32_t *length) {
    (void)payload; (void)position;
    *length = offset < source_length ? source_length - offset : 0;
    return (const char *)source + (offset < source_length ? offset : source_length);
}
static bool progress(TSParseState *state) {
    (void)state;
    return milliseconds() >= parse_deadline || getppid() != owner;
}
static int nesting_kind(const char *kind) {
    static const char *const kinds[] = {"function_definition", "brace_group", "subshell",
        "command_substitution", "backquote_substitution", "process_substitution", "parameter_expansion",
        "arithmetic_expansion", "if_clause", "for_clause", "while_clause",
        "until_clause", "case_clause", "repeat_clause", "select_clause", "arithmetic_for_clause",
        "conditional_group", "glob_group", "brace_expansion", "subscript_group"};
    for (size_t i = 0; i < sizeof(kinds) / sizeof(kinds[0]); i++)
        if (!strcmp(kind, kinds[i])) return 1;
    return 0;
}
static void add_definition(TSNode node, uint32_t depth, int32_t parent) {
    if (result.count == DEFINITION_COUNT) worker_fail(DEFINITIONS);
    Definition *definition = &result.definitions[result.count++];
    definition->unit = span(node);
    definition->depth = depth;
    definition->parent = parent;
    TSNode body = ts_node_child_by_field_name(node, "body", 4);
    definition->body = span(body);
    if (definition->body.start == definition->body.end ||
        !contains(definition->unit, definition->body)) worker_fail(BOUNDARY);
    uint32_t end = definition->unit.start, previous = definition->unit.start;
    TSTreeCursor children = ts_tree_cursor_new(node);
    if (!ts_tree_cursor_goto_first_child(&children)) worker_fail(BOUNDARY);
    do {
        TSNode child = ts_tree_cursor_current_node(&children);
        Span range = span(child);
        if (!contains(definition->unit, range) || range.start < previous) worker_fail(BOUNDARY);
        previous = range.end;
        const char *field = ts_tree_cursor_current_field_name(&children);
        if (field && !strcmp(field, "name")) {
            if (definition->name_count == NAME_COUNT) worker_fail(NAMES);
            if (range.start == range.end || range.end > definition->body.start) worker_fail(BOUNDARY);
            definition->names[definition->name_count++] = range;
        }
        /* Direct children preserve redirects/arguments, including anonymous
         * activation. The grammar may attach trailing whitespace to the unit. */
        if (range.end > end) end = range.end;
    } while (ts_tree_cursor_goto_next_sibling(&children));
    ts_tree_cursor_delete(&children);
    if (end <= definition->unit.start || !whitespace(end, definition->unit.end)) worker_fail(BOUNDARY);
    definition->unit.end = end;
    if (end - definition->unit.start > DEFINITION_LIMIT) worker_fail(DEFINITION_SIZE);
    if (parent >= 0 && !contains(result.definitions[parent].body, definition->unit)) worker_fail(BOUNDARY);
}
static void parse_worker(int output) {
    ts_set_allocator(bounded_malloc, bounded_calloc, bounded_realloc, bounded_free);
    TSParser *parser = ts_parser_new();
    if (!parser || !ts_parser_set_language(parser, tree_sitter_zsh())) worker_fail(INTERNAL);
    parse_deadline = milliseconds() + PARSE_MS;
    TSInput input = {NULL, read_source, TSInputEncodingUTF8, NULL};
    TSParseOptions options = {NULL, progress};
    TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, options);
    if (!tree) worker_fail(TIMEOUT);
    TSNode root = ts_tree_root_node(tree);
    if (ts_node_has_error(root)) worker_fail(SYNTAX);
    Span root_span = span(root);
    if (!whitespace(0, root_span.start) || !whitespace(root_span.end, source_length)) worker_fail(BOUNDARY);
    TSTreeCursor cursor = ts_tree_cursor_new(root);
    uint32_t depth = 0, syntax[TREE_DEPTH + 1] = {0};
    int32_t parents[TREE_DEPTH + 1];
    parents[0] = -1;
    for (;;) {
        TSNode node = ts_tree_cursor_current_node(&cursor);
        if (ts_node_is_error(node) || ts_node_is_missing(node)) worker_fail(SYNTAX);
        (void)span(node);
        if (++result.nodes > NODE_LIMIT) worker_fail(NODES);
        const char *kind = ts_node_type(node);
        /* Whole outer sublists only. Conditions, function bodies, pipelines
         * and substitutions never contribute independent inner statements. */
        if (!strcmp(kind, "sublist") && depth == 2 &&
            !strcmp(ts_node_type(ts_node_parent(node)), "list")) {
            if (result.statement_count < DEFINITION_COUNT)
                result.statements[result.statement_count++] = span(node);
            else result.statement_count = DEFINITION_COUNT + 1;
        }
        uint32_t nested = syntax[depth] + nesting_kind(kind);
        if (nested > SYNTAX_DEPTH) worker_fail(DEPTH);
        if (nested > result.syntax_depth) result.syntax_depth = nested;
        int32_t parent = parents[depth];
        if (!strcmp(kind, "function_definition")) {
            add_definition(node, depth, parent);
            parent = (int32_t)result.count - 1;
        }
        if (parent >= 0) {
            if (!strcmp(kind, "io_here")) heredoc_redirects[parent]++;
            if (!strcmp(kind, "here_document")) heredoc_bodies[parent]++;
        }
        if (ts_tree_cursor_goto_first_child(&cursor)) {
            if (++depth > TREE_DEPTH) worker_fail(DEPTH);
            syntax[depth] = nested;
            parents[depth] = parent;
            continue;
        }
        while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts_tree_cursor_goto_parent(&cursor)) goto complete;
            depth--;
        }
    }
complete:
    /* A definition suffix can own a heredoc whose bytes live in a sibling
     * sequence outside its AST node. Never return that incomplete unit. Nested
     * definitions account independently, so a parent's bytes cannot hide it. */
    for (uint32_t i = 0; i < result.count; i++)
        if (heredoc_redirects[i] != heredoc_bodies[i]) worker_fail(BOUNDARY);
    ts_tree_cursor_delete(&cursor);
    ts_tree_delete(tree);
    ts_parser_delete(parser);
    result.allocation_peak = allocation_peak;
    const unsigned char *bytes = (const unsigned char *)&result;
    size_t written = 0;
    while (written < sizeof(result)) {
        ssize_t count = write(output, bytes + written, sizeof(result) - written);
        if (count <= 0) worker_fail(PROCESS);
        written += (size_t)count;
    }
    _exit(OK);
}

static enum Failure read_input(void) {
    for (;;) {
        enum Failure stop = interrupted();
        if (stop) return stop;
        struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&descriptor, 1, 10);
        if (ready < 0) { if (errno == EINTR) continue; return INPUT_IO; }
        if (!ready) continue;
        ssize_t count = read(STDIN_FILENO, source + source_length, sizeof(source) - source_length);
        if (count < 0) { if (errno == EINTR || errno == EAGAIN) continue; return INPUT_IO; }
        if (!count) return utf8_valid() ? OK : ENCODING;
        source_length += (uint32_t)count;
        if (source_length > INPUT_LIMIT) return INPUT_SIZE;
    }
}
static enum Failure supervise(void (*worker)(int)) {
    int descriptors[2];
    if (pipe(descriptors)) return PROCESS;
    owner = getpid();
    pid_t child = fork();
    if (child < 0) { close(descriptors[0]); close(descriptors[1]); return PROCESS; }
    if (!child) {
        close(descriptors[0]);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
        struct rlimit cpu = {2, 2}, stack = {8 * 1024 * 1024, 8 * 1024 * 1024};
        if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_STACK, &stack)) _exit(PROCESS);
        /* Discard assertion/sanitizer text and inherited streams before parsing.
         * The parent reports only an allowlisted code, never vendor diagnostics. */
        int sink = open("/dev/null", O_RDWR);
        if (sink < 0) _exit(PROCESS);
        if (dup2(sink, 0) < 0 || dup2(sink, 1) < 0 || dup2(sink, 2) < 0) _exit(PROCESS);
        if (dup2(descriptors[1], 3) < 0) _exit(PROCESS);
        int descriptor_limit = getdtablesize();
        if (descriptor_limit < 4 || descriptor_limit > 65536) _exit(PROCESS);
        for (int descriptor = 4; descriptor < descriptor_limit; descriptor++) close(descriptor);
        worker(3);
        _exit(PROCESS);
    }
    close(descriptors[1]);
    enum Failure failure = OK;
    size_t received = 0;
    int status = 0, reaped = 0;
    int64_t exit_observation_deadline = 0;
    for (;;) {
        if ((failure = interrupted())) break;
        struct pollfd descriptor = {descriptors[0], POLLIN, 0};
        int ready = poll(&descriptor, 1, 10);
        if (ready < 0 && errno != EINTR) { failure = PROCESS; break; }
        if (ready > 0) {
            unsigned char buffer[4096];
            ssize_t count = read(descriptors[0], buffer, sizeof(buffer));
            if (count < 0 && errno != EINTR) { failure = PROCESS; break; }
            if (count > 0) {
                if ((size_t)count > sizeof(result) - received) { failure = OUTPUT; break; }
                memcpy((unsigned char *)&result + received, buffer, (size_t)count);
                received += (size_t)count;
            }
        }
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) { reaped = 1; break; }
        if (waited < 0 && errno != EINTR) { failure = PROCESS; break; }
        struct proc_taskinfo info;
        int observed = proc_pidinfo(child, PROC_PIDTASKINFO, 0, &info, sizeof(info));
        if (observed == sizeof(info) && info.pti_resident_size > RSS_LIMIT) { failure = MEMORY; break; }
        /* Exit may race this observation. Reap or fail closed on an unavailable
         * measurement while the worker is still alive. */
        if (observed != sizeof(info)) {
            int observation_error = errno;
            if (waitpid(child, &status, WNOHANG) == child) { reaped = 1; break; }
            /* Darwin can remove task info just before waitpid sees the exit.
             * Permit only this bounded ESRCH transition, never success without
             * the final exit status and the entire worker response. */
            if (!exit_observation_deadline) exit_observation_deadline = milliseconds() + 50;
            if (observation_error != ESRCH || milliseconds() >= exit_observation_deadline) {
                failure = PROCESS; break;
            }
        }
    }
    if (!reaped) {
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    if (!failure && (!WIFEXITED(status) || WEXITSTATUS(status) >= sizeof(codes) / sizeof(codes[0]))) failure = PROCESS;
    if (!failure && WEXITSTATUS(status)) failure = (enum Failure)WEXITSTATUS(status);
    if (!failure) {
        /* A successful exited worker has closed its pipe; drain the finite tail. */
        for (;;) {
            unsigned char buffer[4096];
            ssize_t count = read(descriptors[0], buffer, sizeof(buffer));
            if (!count) break;
            if (count < 0) { if (errno == EINTR) continue; failure = PROCESS; break; }
            if ((size_t)count > sizeof(result) - received) { failure = OUTPUT; break; }
            memcpy((unsigned char *)&result + received, buffer, (size_t)count);
            received += (size_t)count;
        }
        if (!failure && received != sizeof(result)) failure = PROCESS;
    }
    close(descriptors[0]);
    return failure;
}

static char output[OUTPUT_LIMIT];
static size_t output_length;
static int append(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int count = vsnprintf(output + output_length, sizeof(output) - output_length, format, arguments);
    va_end(arguments);
    if (count < 0 || (size_t)count >= sizeof(output) - output_length) return 0;
    output_length += (size_t)count;
    return 1;
}
static int valid_response_span(Span value) {
    return value.start < value.end && byte_boundary(value.start) && byte_boundary(value.end);
}
static enum Failure encode(void) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    CC_SHA256(source, source_length, digest);
    for (size_t i = 0; i < sizeof(digest); i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (result.count > DEFINITION_COUNT || !result.nodes || result.nodes > NODE_LIMIT ||
        result.syntax_depth > SYNTAX_DEPTH || !result.allocation_peak ||
        result.allocation_peak > ALLOCATION_LIMIT) return PROCESS;
    if (!append("{\"schema\":1,\"profile\":\"zsh-default-1\",\"status\":\"ok\",\"code\":\"ok\","
                "\"bytes\":%u,\"sha256\":\"%s\",\"nodes\":%u,\"syntax_depth\":%u,"
                "\"allocation_peak\":%llu,\"definitions\":[", source_length, hex, result.nodes,
                result.syntax_depth, (unsigned long long)result.allocation_peak)) return OUTPUT;
    for (uint32_t i = 0; i < result.count; i++) {
        Definition *d = &result.definitions[i];
        if (d->name_count > NAME_COUNT || !valid_response_span(d->unit) ||
            !valid_response_span(d->body) || !contains(d->unit, d->body) ||
            d->unit.end - d->unit.start > DEFINITION_LIMIT || d->depth > TREE_DEPTH ||
            d->parent < -1 || d->parent >= (int32_t)i ||
            (i && d->unit.start <= result.definitions[i - 1].unit.start) ||
            (d->parent >= 0 && !contains(result.definitions[d->parent].body, d->unit))) return PROCESS;
        for (uint32_t j = 0; j < d->name_count; j++)
            if (!valid_response_span(d->names[j]) || !contains(d->unit, d->names[j]) ||
                d->names[j].end > d->body.start ||
                (j && d->names[j].start < d->names[j - 1].end)) return PROCESS;
        if (!append("%s{\"span\":[%u,%u],\"body\":[%u,%u],\"parent\":%d,\"depth\":%u,\"names\":[",
                    i ? "," : "", d->unit.start, d->unit.end, d->body.start, d->body.end, d->parent, d->depth)) return OUTPUT;
        for (uint32_t j = 0; j < d->name_count; j++)
            if (!append("%s[%u,%u]", j ? "," : "", d->names[j].start, d->names[j].end)) return OUTPUT;
        if (!append("]}")) return OUTPUT;
    }
    if (!append("],\"statements\":")) return OUTPUT;
    if (result.statement_count > DEFINITION_COUNT)
        return append("null}\n") ? OK : OUTPUT;
    if (!append("[")) return OUTPUT;
    for (uint32_t i = 0; i < result.statement_count; i++) {
        Span unit = result.statements[i];
        if (!valid_response_span(unit) || (i && unit.start < result.statements[i - 1].end)) return PROCESS;
        if (!append("%s[%u,%u]", i ? "," : "", unit.start, unit.end)) return OUTPUT;
    }
    return append("]}\n") ? OK : OUTPUT;
}
static int publish(void) {
    int flags = fcntl(STDOUT_FILENO, F_GETFL);
    if (flags < 0 || fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK)) return 2;
    size_t sent = 0;
    /* Bounded output even if the consumer stops reading. A truncated response is
     * never success; consumers must check exit status and one complete record. */
    int64_t until = milliseconds() + 100;
    while (sent < output_length && milliseconds() < until) {
        ssize_t count = write(STDOUT_FILENO, output + sent, output_length - sent);
        if (count > 0) sent += (size_t)count;
        else if (errno == EAGAIN || errno == EINTR) {
            struct pollfd descriptor = {STDOUT_FILENO, POLLOUT, 0};
            (void)poll(&descriptor, 1, 5);
        } else break;
    }
    (void)fcntl(STDOUT_FILENO, F_SETFL, flags);
    return sent == output_length && !cancelled ? 0 : 2;
}
int main(int argc, char **argv) {
    struct rlimit core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &core)) return 2;
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action = {0};
    action.sa_handler = cancel_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) return 2;
    deadline = milliseconds() + PROCESS_MS;
    if (argc == 2 && !strcmp(argv[1], "--version")) {
        append("{\"helper\":1,\"grammar\":\"0.8.0\",\"revision\":\"17651db6e3a413b22e148c8a57726d4b392d10f7\","
               "\"runtime\":\"0.27.2\",\"profile\":\"zsh-default-1\"}\n");
        return publish();
    }
    enum Failure failure = argc == 1 ? read_input() : ARGUMENT;
    if (!failure) failure = supervise(parse_worker);
    if (!failure) failure = interrupted();
    if (!failure) failure = encode();
    if (!failure) failure = interrupted();
    if (failure) {
        output_length = 0;
        append("{\"schema\":1,\"profile\":\"zsh-default-1\",\"status\":\"error\",\"code\":\"%s\",\"definitions\":[]}\n", codes[failure]);
    }
    int written = publish();
    return failure || written ? 2 : 0;
}
