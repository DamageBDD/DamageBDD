/* SPDX-License-Identifier: Apache-2.0
 * One-shot guest agent. No host networking or host filesystem is required.
 * Wire format: network byte order; bounded lengths; never deserialize terms.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/vm_sockets.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_SCRIPT 65536U
#define MAX_OUTPUT 1048576U

static int read_all(int fd, void *buffer, size_t size) {
    unsigned char *p = buffer;
    while (size) {
        ssize_t n = read(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n; size -= (size_t)n;
    }
    return 0;
}
static int write_all(int fd, const void *buffer, size_t size) {
    const unsigned char *p = buffer;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n; size -= (size_t)n;
    }
    return 0;
}
static int limit(int resource, rlim_t value) {
    struct rlimit lim = {value, value};
    return setrlimit(resource, &lim);
}

static int execute_script(int connection) {
    uint32_t frame[3];
    if (read_all(connection, frame, sizeof frame) || memcmp(frame, "DFC1", 4)) return 1;
    uint32_t script_len = ntohl(frame[1]), max_output = ntohl(frame[2]);
    if (!script_len || script_len > MAX_SCRIPT || !max_output || max_output > MAX_OUTPUT) return 1;
    unsigned char *script = malloc(script_len), *output = malloc(max_output);
    if (!script || !output) { free(script); free(output); return 1; }
    int rc = 1, script_fd = -1, pipefd[2] = {-1, -1};
    if (read_all(connection, script, script_len) || memchr(script, 0, script_len)) goto out;
    script_fd = open("/work/job.sh", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0444);
    if (script_fd < 0 || write_all(script_fd, script, script_len)) goto out;
    close(script_fd); script_fd = -1;
    free(script); script = NULL;
    if (pipe2(pipefd, O_CLOEXEC)) goto out;
    pid_t child = fork();
    if (child < 0) goto out;
    if (child == 0) {
        close(pipefd[0]);
        close(connection);
        if (setpgid(0, 0)) _exit(125);
        int nullfd = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (nullfd < 0 || dup2(nullfd, STDIN_FILENO) < 0 ||
            dup2(pipefd[1], STDOUT_FILENO) < 0 || dup2(pipefd[1], STDERR_FILENO) < 0) _exit(125);
        if (nullfd > 2) close(nullfd);
        if (pipefd[1] > 2) close(pipefd[1]);
        umask(077);
        if (limit(RLIMIT_CORE, 0) || limit(RLIMIT_NOFILE, 64) ||
            limit(RLIMIT_NPROC, 64) || limit(RLIMIT_FSIZE, 64 * 1024 * 1024) ||
            setgroups(0, NULL) || setgid(1000) || setuid(1000) ||
            prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || chdir("/work") || clearenv()) _exit(125);
        if (setenv("PATH", "/usr/local/bin:/usr/bin:/bin", 1) ||
            setenv("HOME", "/work", 1) || setenv("TMPDIR", "/tmp", 1) || setenv("LANG", "C", 1)) _exit(125);
        execl("/bin/sh", "sh", "/work/job.sh", (char *)NULL);
        _exit(127);
    }
    (void)setpgid(child, child);
    close(pipefd[1]); pipefd[1] = -1;
    int flags = fcntl(pipefd[0], F_GETFL, 0);
    if (flags < 0 || fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK) < 0) {
        kill(-child, SIGKILL); waitpid(child, NULL, 0); goto out;
    }
    size_t used = 0;
    int truncated = 0, status = 0, done = 0, eof = 0;
    while (!done || !eof) {
        struct pollfd pfd = {eof ? -1 : pipefd[0], POLLIN | POLLHUP, 0};
        if (poll(&pfd, 1, 50) < 0 && errno != EINTR) { kill(-child, SIGKILL); break; }
        if (pfd.revents & (POLLIN | POLLHUP)) {
            unsigned char block[4096];
            ssize_t n = read(pipefd[0], block, sizeof block);
            if (n > 0) {
                size_t available = max_output - used;
                size_t copy = (size_t)n < available ? (size_t)n : available;
                memcpy(output + used, block, copy); used += copy;
                if ((size_t)n > copy) { truncated = 1; kill(-child, SIGKILL); }
            } else if (n == 0) eof = 1;
            else if (errno != EINTR && errno != EAGAIN) { kill(-child, SIGKILL); break; }
        }
        if (!done) {
            pid_t w = waitpid(child, &status, WNOHANG);
            if (w == child) { done = 1; kill(-child, SIGKILL); }
            else if (w < 0 && errno != EINTR) { kill(-child, SIGKILL); break; }
        }
        /* Host deadline destroys the VM if a daemon escaped the process group
         * or a compromised guest tries to withhold EOF/result. */
    }
    if (!done) {
        while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) goto out; }
    }
    uint32_t code = WIFEXITED(status) ? (uint32_t)WEXITSTATUS(status) :
                    WIFSIGNALED(status) ? (uint32_t)(128 + WTERMSIG(status)) : 125U;
    uint32_t reply[4] = {0, htonl(code), htonl((uint32_t)truncated), htonl((uint32_t)used)};
    memcpy(reply, "DFR1", 4);
    rc = write_all(connection, reply, sizeof reply) || write_all(connection, output, used);
out:
    if (script_fd >= 0) close(script_fd);
    if (pipefd[0] >= 0) close(pipefd[0]);
    if (pipefd[1] >= 0) close(pipefd[1]);
    free(script); free(output);
    return rc;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    /* PID 1 must explicitly opt in to child notification. */
    signal(SIGCHLD, SIG_DFL);
    int listener = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_vm addr = {0};
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = 19000;
    if (listener < 0 || bind(listener, (struct sockaddr *)&addr, sizeof addr) || listen(listener, 1)) return 1;
    int connection = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    close(listener);
    if (connection < 0) return 1;
    int rc = execute_script(connection);
    close(connection);
    /* Keep PID 1 alive until the host has received the result and kills the VM. */
    if (getpid() == 1) for (;;) pause();
    return rc;
}
