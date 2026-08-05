#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "CObscuraProcess.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#if defined(__linux__)
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif
#include <unistd.h>

static int make_cloexec_pipe(int fds[2]) {
#if defined(__linux__)
    if (pipe2(fds, O_CLOEXEC) == 0) {
        return 0;
    }
    if (errno != ENOSYS) {
        return -1;
    }
#endif
    if (pipe(fds) != 0) {
        return -1;
    }
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) == -1 ||
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) == -1) {
        const int saved = errno;
        close(fds[0]);
        close(fds[1]);
        errno = saved;
        return -1;
    }
    return 0;
}

static void close_pair(int fds[2]) {
    if (fds[0] >= 0) {
        close(fds[0]);
    }
    if (fds[1] >= 0) {
        close(fds[1]);
    }
}

static void child_report_exec_error(int fd, int error_number) {
    const uint8_t *cursor = (const uint8_t *)&error_number;
    size_t remaining = sizeof(error_number);
    while (remaining > 0) {
        const ssize_t written = write(fd, cursor, remaining);
        if (written > 0) {
            cursor += written;
            remaining -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

static int inherited_fd_limit(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY) {
        if (limit.rlim_cur > (rlim_t)INT_MAX) {
            return INT_MAX;
        }
        return (int)limit.rlim_cur;
    }

    const long open_max = sysconf(_SC_OPEN_MAX);
    if (open_max > 0 && open_max <= INT_MAX) {
        return (int)open_max;
    }
    return 1024 * 1024;
}

static int move_fd_above_stdio(int fd) {
    if (fd > STDERR_FILENO) {
        return fd;
    }
#if defined(F_DUPFD_CLOEXEC)
    const int duplicated = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
#else
    const int duplicated = fcntl(fd, F_DUPFD, STDERR_FILENO + 1);
    if (duplicated >= 0 && fcntl(duplicated, F_SETFD, FD_CLOEXEC) == -1) {
        const int saved = errno;
        close(duplicated);
        errno = saved;
        return -1;
    }
#endif
    if (duplicated == -1) {
        return -1;
    }
    close(fd);
    return duplicated;
}

static void close_inherited_fds_except(int first_fd, int maximum_fd, int preserved_fd) {
#if defined(__linux__) && defined(SYS_close_range)
    int left_result = 0;
    int right_result = 0;
    if (preserved_fd >= first_fd) {
        if (preserved_fd > first_fd) {
            left_result = (int)syscall(
                SYS_close_range,
                (unsigned int)first_fd,
                (unsigned int)(preserved_fd - 1),
                0
            );
        }
        if (preserved_fd < INT_MAX) {
            right_result = (int)syscall(
                SYS_close_range,
                (unsigned int)(preserved_fd + 1),
                UINT_MAX,
                0
            );
        }
    } else {
        right_result = (int)syscall(SYS_close_range, (unsigned int)first_fd, UINT_MAX, 0);
    }
    if (left_result == 0 && right_result == 0) {
        return;
    }
#endif
    for (int fd = first_fd; fd < maximum_fd; ++fd) {
        if (fd != preserved_fd) {
            close(fd);
        }
    }
}

int32_t obscura_spawn_process(
    const char *executable,
    char *const argv[],
    char *const envp[],
    obscura_spawn_result *result
) {
    if (executable == NULL || argv == NULL || envp == NULL || result == NULL) {
        return EINVAL;
    }

    result->pid = -1;
    result->stdout_fd = -1;
    result->stderr_fd = -1;
    result->error_number = 0;

    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    int exec_pipe[2] = {-1, -1};

    if (make_cloexec_pipe(stdout_pipe) != 0 ||
        make_cloexec_pipe(stderr_pipe) != 0 ||
        make_cloexec_pipe(exec_pipe) != 0) {
        const int saved = errno;
        close_pair(stdout_pipe);
        close_pair(stderr_pipe);
        close_pair(exec_pipe);
        return saved;
    }

    const int maximum_fd = inherited_fd_limit();
    const pid_t parent_pid = getpid();
    const pid_t pid = fork();
    if (pid < 0) {
        const int saved = errno;
        close_pair(stdout_pipe);
        close_pair(stderr_pipe);
        close_pair(exec_pipe);
        return saved;
    }

    if (pid == 0) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        close(exec_pipe[0]);

#if defined(__linux__)
        // The Swift owner may be terminated before it can run orderly actor
        // cleanup. Bind the engine lifetime to that exact parent and close the
        // race where the parent dies between fork() and PR_SET_PDEATHSIG.
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) == -1) {
            const int saved = errno;
            child_report_exec_error(exec_pipe[1], saved);
            _exit(127);
        }
        if (getppid() != parent_pid) {
            _exit(127);
        }
#endif

        int exec_error_fd = move_fd_above_stdio(exec_pipe[1]);
        if (exec_error_fd == -1) {
            const int saved = errno;
            child_report_exec_error(exec_pipe[1], saved);
            _exit(127);
        }
        int child_stdout_fd = move_fd_above_stdio(stdout_pipe[1]);
        if (child_stdout_fd == -1) {
            const int saved = errno;
            child_report_exec_error(exec_error_fd, saved);
            _exit(127);
        }
        int child_stderr_fd = move_fd_above_stdio(stderr_pipe[1]);
        if (child_stderr_fd == -1) {
            const int saved = errno;
            child_report_exec_error(exec_error_fd, saved);
            _exit(127);
        }

        if (setsid() == -1) {
            const int saved = errno;
            child_report_exec_error(exec_error_fd, saved);
            _exit(127);
        }
        if (fcntl(exec_error_fd, F_SETFD, FD_CLOEXEC) == -1) {
            const int saved = errno;
            child_report_exec_error(exec_error_fd, saved);
            _exit(127);
        }

        const int null_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (null_fd == -1 ||
            dup2(null_fd, STDIN_FILENO) == -1 ||
            dup2(child_stdout_fd, STDOUT_FILENO) == -1 ||
            dup2(child_stderr_fd, STDERR_FILENO) == -1) {
            const int saved = errno;
            child_report_exec_error(exec_error_fd, saved);
            _exit(127);
        }

        if (null_fd != STDIN_FILENO) {
            close(null_fd);
        }
        close(child_stdout_fd);
        close(child_stderr_fd);
        close_inherited_fds_except(STDERR_FILENO + 1, maximum_fd, exec_error_fd);

        execve(executable, argv, envp);
        const int saved = errno;
        child_report_exec_error(exec_error_fd, saved);
        _exit(127);
    }

    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    close(exec_pipe[1]);

    int child_error = 0;
    uint8_t *cursor = (uint8_t *)&child_error;
    size_t remaining = sizeof(child_error);
    while (remaining > 0) {
        const ssize_t count = read(exec_pipe[0], cursor, remaining);
        if (count > 0) {
            cursor += count;
            remaining -= (size_t)count;
        } else if (count == 0) {
            break;
        } else if (errno == EINTR) {
            continue;
        } else {
            child_error = errno;
            remaining = 0;
            break;
        }
    }
    close(exec_pipe[0]);

    if (remaining == 0 && child_error != 0) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        int status = 0;
        while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
        }
        result->error_number = child_error;
        return child_error;
    }

    if (remaining != sizeof(child_error) && remaining != 0) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        (void)kill(-pid, SIGKILL);
        int status = 0;
        while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
        }
        result->error_number = EPROTO;
        return EPROTO;
    }

    result->pid = (int32_t)pid;
    result->stdout_fd = stdout_pipe[0];
    result->stderr_fd = stderr_pipe[0];
    return 0;
}

int32_t obscura_wait_process(int32_t pid, int32_t *raw_status) {
    if (pid <= 0 || raw_status == NULL) {
        return EINVAL;
    }
    int status = 0;
    pid_t result;
    do {
        result = waitpid((pid_t)pid, &status, 0);
    } while (result == -1 && errno == EINTR);
    if (result == -1) {
        return errno;
    }
    *raw_status = (int32_t)status;
    return 0;
}

int32_t obscura_try_wait_process(int32_t pid, int32_t *raw_status, int32_t *did_exit) {
    if (pid <= 0 || raw_status == NULL || did_exit == NULL) {
        return EINVAL;
    }
    int status = 0;
    pid_t result;
    do {
        result = waitpid((pid_t)pid, &status, WNOHANG);
    } while (result == -1 && errno == EINTR);
    if (result == -1) {
        return errno;
    }
    *did_exit = result == 0 ? 0 : 1;
    if (result != 0) {
        *raw_status = (int32_t)status;
    }
    return 0;
}

int32_t obscura_signal_process_group(int32_t pid, int32_t signal_number) {
    if (pid <= 0 || signal_number <= 0) {
        return EINVAL;
    }
    if (kill(-(pid_t)pid, signal_number) == 0) {
        return 0;
    }
    return errno;
}

int32_t obscura_process_is_alive(int32_t pid) {
    if (pid <= 0) {
        return 0;
    }
    if (kill((pid_t)pid, 0) == 0) {
        return 1;
    }
    return errno == EPERM ? 1 : 0;
}

int32_t obscura_status_exited(int32_t raw_status) {
    int status = (int)raw_status;
    return WIFEXITED(status) ? 1 : 0;
}

int32_t obscura_status_exit_code(int32_t raw_status) {
    int status = (int)raw_status;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int32_t obscura_status_signaled(int32_t raw_status) {
    int status = (int)raw_status;
    return WIFSIGNALED(status) ? 1 : 0;
}

int32_t obscura_status_term_signal(int32_t raw_status) {
    int status = (int)raw_status;
    return WIFSIGNALED(status) ? WTERMSIG(status) : -1;
}

int32_t obscura_allocate_loopback_port(uint16_t *port_out) {
    if (port_out == NULL) {
        return EINVAL;
    }
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd == -1) {
        return errno;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(0);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        const int saved = errno;
        close(fd);
        return saved;
    }

    socklen_t length = (socklen_t)sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
        const int saved = errno;
        close(fd);
        return saved;
    }
    const uint16_t port = ntohs(address.sin_port);
    close(fd);
    if (port == 0) {
        return EADDRNOTAVAIL;
    }
    *port_out = port;
    return 0;
}
