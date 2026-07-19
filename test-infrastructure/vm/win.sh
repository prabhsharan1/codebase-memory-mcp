#!/usr/bin/env bash
# win.sh — daily driver for the Windows test VM (real-Windows leg of local CI).
#
# All commands run over ssh (local UTM network only — nothing leaves the
# machine). Config: ~/.claude/cbm-vm/config (CBM_VM_HOST, CBM_VM_USER),
# key: ~/.claude/cbm-vm/id_ed25519. Provision first: provision-windows.sh.
#
# Usage:
#   win.sh status                  # reachability + repo + build state
#   win.sh update                  # fetch+reset repo to pushed branch, rebuild
#   win.sh build                   # incremental native build (binary+runner)
#   win.sh test <suite...>         # run test-runner suites (native ARM64)
#   win.sh guards                  # run the Windows guard scripts (python)
#   win.sh smoke-install           # real managed-install E2E (Phase 8 class)
#   win.sh sh <command...>         # arbitrary command in CLANGARM64 env
#   win.sh push-file <local> <vm>  # scp one file into the VM (WIP iteration)
#   win.sh asan-build              # x86_64 CLANG64 build WITH ASan (CI arch)
set -euo pipefail

CONFIG="${HOME}/.claude/cbm-vm/config"
KEY="${HOME}/.claude/cbm-vm/id_ed25519"
[ -f "$CONFIG" ] && . "$CONFIG"
HOST="${CBM_VM_HOST:?set CBM_VM_HOST in ~/.claude/cbm-vm/config}"
USER_="${CBM_VM_USER:-test}"
BRANCH="${CBM_VM_BRANCH:-feat/shared-coordination-daemon}"
JOBS='\$(nproc)'

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o ConnectTimeout=10 -o BatchMode=yes "${USER_}@${HOST}")

vm() { local env="$1"; shift
      "${SSH[@]}" "C:\\msys64\\msys2_shell.cmd -defterm -no-start -${env} -c \"$*\""; }

cmd="${1:-status}"; shift || true
case "$cmd" in
status)
    "${SSH[@]}" "echo VM_REACHABLE & ver"
    vm clangarm64 "cd /c/cbm 2>/dev/null && git log --oneline -1 && ls -la build/c/codebase-memory-mcp.exe build/c/test-runner.exe 2>/dev/null || echo 'repo/build missing — run provision-windows.sh'"
    ;;
update)
    vm clangarm64 "cd /c/cbm && git fetch origin ${BRANCH} && git reset --hard FETCH_HEAD && git log --oneline -1"
    exec "$0" build
    ;;
build)
    vm clangarm64 "cd /c/cbm && make -j${JOBS} -f Makefile.cbm CC=clang CXX=clang++ SANITIZE= cbm build/c/test-runner > /tmp/win-build.log 2>&1 && echo BUILD_OK || (echo BUILD_FAIL; tail -20 /tmp/win-build.log; exit 1)"
    ;;
test)
    [ $# -ge 1 ] || { echo "usage: win.sh test <suite...>" >&2; exit 2; }
    vm clangarm64 "cd /c/cbm && ./build/c/test-runner $* 2>&1 | tail -40"
    ;;
guards)
    vm clangarm64 "cd /c/cbm && for g in tests/windows/test_*.py; do echo \"== \\\$g ==\"; python \\\$g build/c/codebase-memory-mcp.exe 2>&1 | tail -6; done"
    ;;
smoke-install)
    # Real managed install E2E with FULL stderr visible — the exact class the
    # CI smoke Phase 8 exercises but cannot show (probe hides launcher stderr).
    vm clangarm64 "cd /c/cbm && ./build/c/codebase-memory-mcp.exe install 2>&1 | tail -25"
    ;;
sh)
    vm clangarm64 "$*"
    ;;
push-file)
    [ $# -eq 2 ] || { echo "usage: win.sh push-file <local-path> <vm-path>" >&2; exit 2; }
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" "${USER_}@${HOST}:$2"
    ;;
asan-build)
    # x86_64 (CI's exact arch) with ASan, runs under Windows-on-ARM emulation.
    # Slower; use when a finding needs sanitizer confirmation or CI-arch parity.
    vm clang64 "cd /c/cbm && make -j${JOBS} -f Makefile.cbm CC=clang CXX=clang++ build/c/test-runner > /tmp/win-asan-build.log 2>&1 && echo ASAN_BUILD_OK || (echo ASAN_BUILD_FAIL; tail -20 /tmp/win-asan-build.log; exit 1)"
    ;;
*)
    echo "unknown command: $cmd (see header for usage)" >&2; exit 2
    ;;
esac
