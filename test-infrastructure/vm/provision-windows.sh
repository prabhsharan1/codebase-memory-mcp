#!/usr/bin/env bash
# provision-windows.sh — provision the Windows test VM from the macOS host.
#
# Idempotent: safe to re-run at any time; every step skips work already done.
# Recovers a fresh VM (or a lost disk) to fully-built state in one command.
#
# Prerequisites (one-time, manual — see README.md):
#   1. UTM VM with Windows 11 ARM64 installed, CLONED as a backup before
#      drivers, SPICE guest tools installed (network), and
#      windows-bootstrap.ps1 run inside the VM (OpenSSH + authorized key).
#   2. Host config in ~/.claude/cbm-vm/config (KEY=VALUE):
#        CBM_VM_HOST=192.168.64.4
#        CBM_VM_USER=test
#      Key at ~/.claude/cbm-vm/id_ed25519 (see README.md to generate).
#
# Usage:
#   test-infrastructure/vm/provision-windows.sh            # full provision
#   test-infrastructure/vm/provision-windows.sh --update   # repo+build only
set -euo pipefail

CONFIG="${HOME}/.claude/cbm-vm/config"
KEY="${HOME}/.claude/cbm-vm/id_ed25519"
[ -f "$CONFIG" ] && . "$CONFIG"
HOST="${CBM_VM_HOST:?set CBM_VM_HOST in ~/.claude/cbm-vm/config}"
USER_="${CBM_VM_USER:-test}"
BRANCH="${CBM_VM_BRANCH:-feat/shared-coordination-daemon}"
REPO_URL="${CBM_VM_REPO:-https://github.com/DeusData/codebase-memory-mcp.git}"
MSYS2_SFX_URL="https://repo.msys2.org/distrib/msys2-x86_64-latest.sfx.exe"

SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o ConnectTimeout=10 -o BatchMode=yes "${USER_}@${HOST}")

# Run a command inside the given msys2 environment (clangarm64|clang64|msys).
vm() { # vm <env> <command...>
    local env="$1"; shift
    "${SSH[@]}" "C:\\msys64\\msys2_shell.cmd -defterm -no-start -${env} -c \"$*\""
}
vm_cmd() { "${SSH[@]}" "$@"; } # plain cmd.exe

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "0/6 reachability"
vm_cmd "echo VM_OK & ver" | grep -q VM_OK || {
    echo "FATAL: cannot reach ${USER_}@${HOST} over ssh." >&2
    echo "Run windows-bootstrap.ps1 inside the VM first (see README.md)." >&2
    exit 1
}

if [ "${1:-}" != "--update" ]; then
    step "1/6 msys2 base (skip if present)"
    if ! vm_cmd "if exist C:\\msys64\\usr\\bin\\bash.exe echo MSYS2_PRESENT" | grep -q MSYS2_PRESENT; then
        vm_cmd "powershell -Command \"[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -Uri ${MSYS2_SFX_URL} -OutFile C:\\msys2.sfx.exe\""
        vm_cmd "C:\\msys2.sfx.exe -y -oC:\\" >/dev/null
        vm "msys" "pacman-key --init && pacman-key --populate msys2"
    fi

    step "2/6 pacman update (repeat-safe)"
    vm "msys" "rm -f /var/lib/pacman/db.lck; pacman -Syu --noconfirm --noprogressbar" || true

    step "3/6 toolchains: CLANGARM64 (native, fast) + CLANG64 (x86_64 = CI arch, ASan)"
    vm "msys" "pacman -S --noconfirm --noprogressbar --needed \
        git make coreutils \
        mingw-w64-clang-aarch64-clang mingw-w64-clang-aarch64-zlib \
        mingw-w64-clang-aarch64-python mingw-w64-clang-aarch64-ccache \
        mingw-w64-clang-x86_64-clang mingw-w64-clang-x86_64-compiler-rt \
        mingw-w64-clang-x86_64-zlib mingw-w64-clang-x86_64-ccache"
fi

step "4/6 repo clone/update -> /c/cbm @ ${BRANCH}"
if vm "clangarm64" "test -d /c/cbm/.git && echo REPO_PRESENT" | grep -q REPO_PRESENT; then
    vm "clangarm64" "cd /c/cbm && git fetch origin ${BRANCH} && git reset --hard FETCH_HEAD && git log --oneline -1"
else
    vm "clangarm64" "git clone --branch ${BRANCH} --single-branch --depth 200 ${REPO_URL} /c/cbm && cd /c/cbm && git log --oneline -1"
fi

step "5/6 build: native ARM64 binary + launcher + test-runner (no ASan on arm64)"
vm "clangarm64" "cd /c/cbm && make -j\\\$(nproc) -f Makefile.cbm CC=clang CXX=clang++ SANITIZE= cbm build/c/test-runner > /tmp/provision-build.log 2>&1 && echo BUILD_OK || (echo BUILD_FAIL; tail -15 /tmp/provision-build.log; exit 1)"

step "6/6 smoke: binary + test-runner start"
vm "clangarm64" "cd /c/cbm && ./build/c/codebase-memory-mcp.exe --version && ./build/c/test-runner --list-suites | head -3"

printf '\n\033[1mPROVISION COMPLETE\033[0m — daily driving: test-infrastructure/vm/win.sh\n'
