#ifndef AGENTTERM_PTY_H
#define AGENTTERM_PTY_H

#include <sys/types.h>

/// Starts `path` in a new session whose controlling terminal is a new
/// pseudo terminal of the given size.
///
/// On success returns the child's pid and stores the master side of the
/// pseudo terminal in `*master`. On failure returns -1 and stores an errno
/// value in `*error`; nothing is left running or open.
///
/// `argv` and `envp` are NULL terminated. `cwd` may be NULL.
pid_t agentterm_spawn_pty(
    int *master,
    int *error,
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    unsigned short rows,
    unsigned short cols);

#endif
