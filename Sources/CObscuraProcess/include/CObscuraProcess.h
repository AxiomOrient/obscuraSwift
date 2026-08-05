#ifndef C_OBSCURA_PROCESS_H
#define C_OBSCURA_PROCESS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t pid;
    int32_t stdout_fd;
    int32_t stderr_fd;
    int32_t error_number;
} obscura_spawn_result;

int32_t obscura_spawn_process(
    const char *executable,
    char *const argv[],
    char *const envp[],
    obscura_spawn_result *result
);

int32_t obscura_wait_process(int32_t pid, int32_t *raw_status);
int32_t obscura_try_wait_process(int32_t pid, int32_t *raw_status, int32_t *did_exit);
int32_t obscura_signal_process_group(int32_t pid, int32_t signal_number);
int32_t obscura_process_is_alive(int32_t pid);
int32_t obscura_status_exited(int32_t raw_status);
int32_t obscura_status_exit_code(int32_t raw_status);
int32_t obscura_status_signaled(int32_t raw_status);
int32_t obscura_status_term_signal(int32_t raw_status);
int32_t obscura_allocate_loopback_port(uint16_t *port_out);

#ifdef __cplusplus
}
#endif

#endif
