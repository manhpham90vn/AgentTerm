#include "agentterm_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

// Why this is C with fork() and not posix_spawn():
//
// A program only gets terminal signals (SIGWINCH on resize, SIGINT on
// Ctrl-C, SIGHUP on close) if the pseudo terminal is its session's
// controlling terminal. That takes setsid() followed by ioctl(TIOCSCTTY) in
// the child, and posix_spawn has no way to run an ioctl there. Opening the
// slave from a spawn file action does not do it either. It looked as if it
// did, because bash claims the terminal itself when it starts; zsh does not,
// so everything started through a zsh login shell ran without a controlling
// terminal and never heard about resizes.
//
// Between fork() and execve() the child only calls async-signal-safe
// functions, which is what makes fork() acceptable in a threaded process.

pid_t agentterm_spawn_pty(
    int *master_out,
    int *error_out,
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    unsigned short rows,
    unsigned short cols)
{
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        *error_out = errno;
        return -1;
    }
    char slave_name[128];
    if (grantpt(master) != 0 || unlockpt(master) != 0 ||
        ptsname_r(master, slave_name, sizeof(slave_name)) != 0) {
        *error_out = errno;
        close(master);
        return -1;
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);

    // The child reports a failed exec through this pipe. It closes by itself
    // when the exec succeeds.
    int report[2];
    if (pipe(report) != 0) {
        *error_out = errno;
        close(master);
        return -1;
    }
    fcntl(report[0], F_SETFD, FD_CLOEXEC);
    fcntl(report[1], F_SETFD, FD_CLOEXEC);

    struct winsize size = {.ws_row = rows, .ws_col = cols};
    int max_fd = getdtablesize();

    pid_t pid = fork();
    if (pid < 0) {
        *error_out = errno;
        close(master);
        close(report[0]);
        close(report[1]);
        return -1;
    }

    if (pid == 0) {
        // Child. Async-signal-safe calls only from here on.
        int failure = 0;
        if (setsid() < 0) {
            failure = errno;
        }
        int slave = failure ? -1 : open(slave_name, O_RDWR);
        if (!failure && slave < 0) {
            failure = errno;
        }
        if (!failure && ioctl(slave, TIOCSCTTY, 0) != 0) {
            failure = errno;
        }
        if (!failure) {
            ioctl(slave, TIOCSWINSZ, &size);
            dup2(slave, STDIN_FILENO);
            dup2(slave, STDOUT_FILENO);
            dup2(slave, STDERR_FILENO);
            // Nothing of the daemon's (sockets, other terminals) is passed on.
            for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) {
                if (fd != report[1]) {
                    close(fd);
                }
            }
            // The daemon's signal setup is not the program's business.
            for (int number = 1; number < NSIG; number++) {
                signal(number, SIG_DFL);
            }
            sigset_t none;
            sigemptyset(&none);
            sigprocmask(SIG_SETMASK, &none, NULL);

            if (cwd != NULL && chdir(cwd) != 0) {
                failure = errno;
            }
        }
        if (!failure) {
            execve(path, argv, envp);
            failure = errno;
        }
        (void)write(report[1], &failure, sizeof(failure));
        _exit(127);
    }

    // Parent.
    close(report[1]);
    int failure = 0;
    ssize_t got;
    do {
        got = read(report[0], &failure, sizeof(failure));
    } while (got < 0 && errno == EINTR);
    close(report[0]);

    if (got > 0) {
        // The exec did not happen. Collect the child and report why.
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
        close(master);
        *error_out = failure;
        return -1;
    }

    *master_out = master;
    *error_out = 0;
    return pid;
}
