#!/bin/bash
set -euo pipefail

image=${1:-pterodactyl-zig:test}
version=${2:-0.17.0}
containers=()
volume=$(docker volume create)
cleanup() {
    for container in "${containers[@]}"; do
        docker rm -f "$container" >/dev/null
    done
    docker volume rm "$volume" >/dev/null
}
trap cleanup EXIT

expect_exit() {
    local expected=$1 status=0
    shift
    docker run --rm "$@" || status=$?
    if [[ $status != "$expected" ]]; then
        printf 'Expected exit %s, got %s\n' "$expected" "$status" >&2
        return 1
    fi
}

[[ $(docker run --rm "$image") == "$version" ]]
[[ $(docker run --rm "$image" zig version) == "$version" ]]
docker run --rm "$image" bash -euc '
    test "$(id -u)" = 1000
    test "$HOME" = /home/container
    test "$PWD" = "$HOME"
    test -w "$HOME"
    test ! -w /opt/zig/zig
    test ! -w /entrypoint.sh
    test ! -e /tmp/zig.tar.xz
    ! command -v minisign
    ! command -v xz
    git --version
    curl --version
'

# shellcheck disable=SC2016
value='spaces "quotes" * $(touch /home/container/injected); false'
[[ $(docker run --rm --env "VALUE=$value" \
    --env STARTUP='printf "%s\n" "{{VALUE}}"; test ! -e injected' "$image") == "$value" ]]
[[ $(printf 'stop\n' | docker run --rm -i \
    --env STARTUP='read -r command; printf "%s" "$command"' "$image") == stop ]]
expect_exit 23 "$image" bash -c 'exit 23'
expect_exit 23 --env STARTUP='exit 23' "$image"
expect_exit 1 --env STARTUP='false; printf "must not run\n"' "$image"
expect_exit 1 --env STARTUP='false | cat' "$image"
expect_exit 127 --env STARTUP='command-that-does-not-exist' "$image"
expect_exit 2 --env STARTUP='if' "$image"

# Wings chooses the UID/GID and owns its bind mount; the image must not need root.
docker run --rm --user 0:0 --volume "$volume:/home/container" "$image" \
    chown 12345:12345 /home/container
docker run --rm -i --user 12345:12345 --cap-drop ALL --security-opt no-new-privileges \
    --read-only --tmpfs /tmp:rw,nosuid,nodev --volume "$volume:/home/container" \
    "$image" bash -euxs <<'SCRIPT'
test "$(id -u)" = 12345
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
zig init
zig build
./zig-out/bin/container
git init -q
curl --fail --silent --show-error --proto '=https' https://ziglang.org/ -o /dev/null
version=$(zig version)
zig fetch --save=zig_sources "https://ziglang.org/download/$version/zig-$version.tar.xz"
grep -q zig_sources build.zig.zon
zig build
cat > signal.c <<'C'
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGINT);
    if (sigprocmask(SIG_BLOCK, &signals, NULL)) return 1;
    pid_t child = fork();
    if (child < 0) return 2;
    const char *name = child ? "parent" : "child";
    printf("%s ready\n", name);
    fflush(stdout);
    int received;
    if (sigwait(&signals, &received)) return 4;
    sleep(1);
    printf("%s signal %d\n", name, received);
    fflush(stdout);
    if (child) {
        int status;
        if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 3;
    }
    return 0;
}
C
zig cc -Wall -Wextra -Werror signal.c -o signal
SCRIPT

for signal in TERM INT; do
    # Keep an intermediate shell to check forwarding to the whole process group.
    container=$(docker run -dit --user 12345:12345 --cap-drop ALL \
        --security-opt no-new-privileges --read-only --tmpfs /tmp:rw,nosuid,nodev \
        --volume "$volume:/home/container" --env STARTUP='./signal; exit $?' "$image")
    containers+=("$container")
    ready=false
    for ((attempt = 0; attempt < 100; attempt++)); do
        logs=$(docker logs "$container")
        if [[ $logs == *'parent ready'* && $logs == *'child ready'* ]]; then
            ready=true
            break
        fi
        sleep 0.1
    done
    [[ $ready == true ]]
    docker kill --signal "$signal" "$container" >/dev/null
    status=$(timeout 10 docker wait "$container")
    case "$signal" in
        TERM) [[ $status == 143 ]] ;;
        INT) [[ $status == 130 ]] ;;
    esac
    logs=$(docker logs "$container")
    [[ $logs == *'parent signal '* && $logs == *'child signal '* ]]
done

printf 'Passed: Zig %s, startup, permissions, builds, HTTPS dependencies, stdin, TERM and INT\n' "$version"
