#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/obscura-process-verification.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/parent_death.c" <<'C'
#include "CObscuraProcess.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        return 64;
    }
    char *child_argv[] = {"/bin/sleep", "30", NULL};
    char *child_env[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    obscura_spawn_result result;
    int32_t error = obscura_spawn_process("/bin/sleep", child_argv, child_env, &result);
    if (error != 0) {
        return error;
    }
    FILE *file = fopen(argv[1], "w");
    if (file == NULL) {
        return errno;
    }
    if (fprintf(file, "%d\n", result.pid) < 0 || fclose(file) != 0) {
        return EIO;
    }
    return 0;
}
C

SANITIZERS="-fsanitize=address,undefined"
if [[ "$(uname -s)" == "Linux" ]]; then
  clang -std=c11 -O1 -g -Wall -Wextra -Werror $SANITIZERS \
    -I "$ROOT/Sources/CObscuraProcess/include" \
    "$ROOT/Sources/CObscuraProcess/spawn.c" "$WORK/parent_death.c" \
    -o "$WORK/parent_death"

  pid_file="$WORK/child.pid"
  ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$WORK/parent_death" "$pid_file"
  child_pid="$(cat "$pid_file")"
  for _ in $(seq 1 100); do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      echo "linux parent-death containment verified"
      exit 0
    fi
    sleep 0.02
  done
  kill -KILL "$child_pid" 2>/dev/null || true
  echo "error: child survived owner process termination (pid $child_pid)" >&2
  exit 1
fi

echo "parent-death signal verification skipped: Linux PR_SET_PDEATHSIG is unavailable on $(uname -s)"
