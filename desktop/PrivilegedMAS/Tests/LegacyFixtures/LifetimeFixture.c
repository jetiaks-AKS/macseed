// Rootless test executable only; never packaged in the helper app.
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
int main(int argc, char **argv) {
    if (argc != 2) return 64;
    const char *marker = getenv("LIFETIME_MARKER");
    if (marker) { int fd = open(marker, O_CREAT | O_EXCL | O_WRONLY, 0600); if (fd < 0) return 65; write(fd, "ran", 3); close(fd); }
    if (!strcmp(argv[1], "exec")) { execl("/usr/bin/true", "true", (char *)0); return 66; }
    if (!strcmp(argv[1], "fork")) { pid_t child = fork(); if (child < 0) return 67; if (!child) { usleep(100000); _exit(0); } return 0; }
    if (!strcmp(argv[1], "crash-after")) usleep(2000000);
    if (!strcmp(argv[1], "error")) return 73;
    if (!strcmp(argv[1], "slow")) usleep(100000);
    return 0;
}
