/*
 * android_runas — run a command as the Termux app user with the
 * untrusted_app SELinux context (Stage 4 helper).
 *
 * Why this exists: inside the Alpine chroot the default process runs as
 * root in the Magisk domain.  Android's audio stack (OpenSL ES / audioserver)
 * only accepts capture clients from the Termux app uid and its
 * untrusted_app context.  This helper drops uid/gid, keeps the capabilities
 * needed to change the SELinux context, switches to the Termux process
 * context and execs the Termux binary.
 *
 * It is installed by scripts/termux-mic-setup.sh into
 * $PREFIX/bin/runas-ctx with the same SELinux label as the Termux shell.
 *
 * Usage: runas-ctx UID CONTEXT CMD [ARG...]
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Avoid a dependency on linux/capability.h (not present in minimal Alpine). */
struct cap_hdr {
    unsigned int version;
    int pid;
};
struct cap_data {
    unsigned int effective;
    unsigned int permitted;
    unsigned int inheritable;
};
#define CAP_VERSION_3 0x20080522

static int write_all(int fd, const char *s)
{
    size_t n = strlen(s);
    ssize_t w = write(fd, s, n);
    return w == (ssize_t)n ? 0 : -1;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: runas-ctx UID CONTEXT CMD [args...]\n");
        return 2;
    }

    uid_t uid = (uid_t)atoi(argv[1]);
    const char *ctx = argv[2];

    setgroups(0, NULL);
    if (setgid(uid) != 0) {
        perror("setgid");
        return 1;
    }
    if (prctl(PR_SET_KEEPCAPS, 1, 0, 0, 0) != 0) {
        perror("prctl(PR_SET_KEEPCAPS)");
        return 1;
    }
    if (setuid(uid) != 0) {
        perror("setuid");
        return 1;
    }

    struct cap_hdr hdr = { CAP_VERSION_3, 0 };
    struct cap_data data[2] = {
        { 0xffffffff, 0xffffffff, 0 },
        { 0xffffffff, 0xffffffff, 0 },
    };
    if (syscall(SYS_capset, &hdr, data) != 0) {
        perror("capset");
        return 1;
    }

    int fd = open("/proc/self/attr/current", O_WRONLY);
    if (fd < 0) {
        perror("open /proc/self/attr/current");
        return 1;
    }
    if (write_all(fd, ctx) != 0) {
        perror("write /proc/self/attr/current");
        close(fd);
        return 1;
    }
    close(fd);

    execvp(argv[3], &argv[3]);
    perror("execvp");
    return 1;
}
