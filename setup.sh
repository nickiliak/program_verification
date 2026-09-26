#!/usr/bin/env bash
#
# Sets up this workspace from a fresh clone:
#
#   1. makes sure the jpamb submodule is checked out (recursively)
#   2. builds the .jpamb-eval virtualenv described in jpamb/docs/python.md
#   3. installs JPAMB and the syntactic solution into it, editable
#   4. runs `jpamb checkhealth` to prove it works
#
# Safe to re-run: an existing, healthy venv is reused. Use --clear to rebuild.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JPAMB_DIR="$REPO_ROOT/jpamb"
VENV_DIR="$JPAMB_DIR/.jpamb-eval"
VENV_NAME="jpamb-eval"

# Relative to $JPAMB_DIR, so both the install and the printed hints agree.
SYNTACTIC_DIR="solutions/syntactic"
ASSIGNMENT="../assignments/assign1/my_solution/syntactic_analysis.py"

CLEAR=0
INSTALL_SYNTACTIC=1
RUN_CHECKHEALTH=1
FORCE_SUBMODULE=0

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    BOLD=''; RED=''; GREEN=''; YELLOW=''; RESET=''
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %swarning%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
usage: setup.sh [options]

Prepares the program_verification workspace: checks out the jpamb submodule and
builds the .jpamb-eval virtualenv from jpamb/docs/python.md.

options:
  --clear             recreate the virtualenv from scratch instead of reusing it
  --no-syntactic      only install JPAMB, skip solutions/syntactic (and with it
                      tree-sitter, which the assignment code imports)
  --skip-checkhealth  do not run 'jpamb checkhealth' at the end
  --force-submodule   reset the submodule to the pinned commit even when it is
                      checked out somewhere else (discards that checkout)
  -h, --help          show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --clear)             CLEAR=1 ;;
        --no-syntactic)      INSTALL_SYNTACTIC=0 ;;
        --skip-checkhealth)  RUN_CHECKHEALTH=0 ;;
        --force-submodule)   FORCE_SUBMODULE=1 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- prerequisites

step "Checking prerequisites"

command -v git >/dev/null 2>&1 || die "git is required. See https://git-scm.com/downloads"
ok "git $(git --version | awk '{print $3}')"

if command -v gcc >/dev/null 2>&1; then
    ok "gcc $(gcc -dumpversion)"
else
    # The 'runit' dependency builds a C extension (timer.c), so this is not optional.
    die "gcc is required to build JPAMB's dependencies.
    On Ubuntu/Debian: sudo apt update && sudo apt install build-essential
    See jpamb/docs/setup.md for macOS and Windows."
fi

if ! command -v uv >/dev/null 2>&1; then
    # uv installs into ~/.local/bin, so this needs no sudo.
    info "uv not found, installing it (https://astral.sh/uv)"
    command -v curl >/dev/null 2>&1 ||
        die "cannot install uv without curl. Install uv manually: https://docs.astral.sh/uv/getting-started/installation/"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 ||
        die "uv was installed but is not on PATH. Restart your shell and re-run setup.sh."
    UV_WAS_INSTALLED=1
else
    UV_WAS_INSTALLED=0
fi
ok "uv $(uv --version | awk '{print $2}')"

if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
    ok "docker/podman"
else
    # checkhealth defaults to --no-docker; docker is only needed to rebuild the
    # benchmark's class files from source.
    warn "neither docker nor podman found. That is fine for running analyses,
    but 'jpamb build' and 'jpamb checkhealth --docker' will not work."
fi

# ------------------------------------------------------------------- submodule

step "Checking out the jpamb submodule"

cd "$REPO_ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_ROOT is not a git repository."

# `git submodule status` prefixes the sha: '-' not initialised, '+' checked out
# at a commit other than the pinned one, ' ' in sync.
submodule_status="$(git submodule status jpamb 2>/dev/null || true)"
[ -n "$submodule_status" ] || die "no 'jpamb' submodule registered in $REPO_ROOT/.gitmodules"

case "$submodule_status" in
    -*)
        info "submodule not initialised, cloning it"
        git submodule update --init --recursive jpamb
        ;;
    +*)
        if [ "$FORCE_SUBMODULE" -eq 1 ]; then
            warn "submodule is at a different commit, resetting it as requested"
            git submodule update --init --recursive --force jpamb
        else
            warn "jpamb is checked out at a commit other than the pinned one.
    Leaving it alone so local work is not lost. Re-run with --force-submodule
    to reset it to $(git ls-tree HEAD jpamb | awk '{print substr($3, 1, 8)}')."
        fi
        ;;
    *)
        git submodule update --init --recursive jpamb
        ;;
esac

[ -f "$JPAMB_DIR/pyproject.toml" ] || die "jpamb/pyproject.toml is missing — the submodule checkout looks incomplete."
ok "jpamb at $(git -C "$JPAMB_DIR" describe --tags --always 2>/dev/null || echo 'unknown revision')"

# --------------------------------------------------------------------- venv

# Run from the submodule so uv picks up jpamb/.python-version (cpython 3.13.5).
cd "$JPAMB_DIR"

# Prints why the existing venv cannot be reused, or nothing if it can be.
venv_problem() {
    if [ ! -x "$VENV_DIR/bin/python" ] || [ ! -f "$VENV_DIR/pyvenv.cfg" ] || [ ! -f "$VENV_DIR/bin/activate" ]; then
        echo "it is incomplete"
        return
    fi

    # bin/activate has the venv's path baked in at creation time and nothing
    # rewrites it afterwards, so a venv whose directory was moved (or a repo that
    # was renamed) would activate into a path that no longer exists.
    local recorded
    recorded="$(sed -n "s/^VIRTUAL_ENV=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}[[:space:]]*$/\1/p" "$VENV_DIR/bin/activate" | head -n 1)"
    if [ "$recorded" != "$VENV_DIR" ]; then
        echo "it was created at ${recorded:-an unknown path} and has since been moved"
        return
    fi

    # JPAMB requires >= 3.13.
    if ! "$VENV_DIR/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 13) else 1)' 2>/dev/null; then
        echo "its Python is older than the 3.13 JPAMB requires"
        return
    fi
}

step "Preparing the virtualenv at jpamb/.jpamb-eval"

if [ "$CLEAR" -eq 1 ]; then
    info "recreating it from scratch (--clear)"
    uv venv --no-project --clear --prompt "$VENV_NAME" .jpamb-eval
elif [ ! -d "$VENV_DIR" ]; then
    info "creating it"
    uv venv --no-project --prompt "$VENV_NAME" .jpamb-eval
else
    problem="$(venv_problem)"
    if [ -z "$problem" ]; then
        ok "reusing the existing environment ($("$VENV_DIR/bin/python" -V))"
    else
        warn "recreating the existing environment: $problem"
        uv venv --no-project --clear --prompt "$VENV_NAME" .jpamb-eval
    fi
fi

problem="$(venv_problem)"
[ -z "$problem" ] || die "the virtualenv at $VENV_DIR is still not usable: $problem
    Try: ./setup.sh --clear"

VENV_PYTHON="$VENV_DIR/bin/python"

# ------------------------------------------------------------------ installs

step "Installing packages"

# --python instead of activating, so the script never depends on sourcing anything.
info "JPAMB (editable)"
uv pip install --quiet --python "$VENV_PYTHON" --editable .

if [ "$INSTALL_SYNTACTIC" -eq 1 ]; then
    # This is the tutorial's example solution, and it is what pulls in tree-sitter
    # and tree-sitter-java — the third-party imports the assignment code uses.
    info "$SYNTACTIC_DIR (editable, brings tree-sitter)"
    uv pip install --quiet --python "$VENV_PYTHON" --editable "$SYNTACTIC_DIR"
else
    warn "skipping $SYNTACTIC_DIR (--no-syntactic): tree-sitter will not be installed."
fi
ok "packages installed"

# --------------------------------------------------------------- checkhealth

if [ "$RUN_CHECKHEALTH" -eq 1 ]; then
    step "Running jpamb checkhealth"
    if "$VENV_DIR/bin/jpamb" checkhealth; then
        ok "checkhealth passed"
    else
        # The environment is still built; this is diagnostic, not fatal.
        warn "checkhealth reported problems. See the troubleshooting section in
    jpamb/docs/setup.md."
    fi
fi

# -------------------------------------------------------------- next steps

cat <<EOF

${BOLD}Setup complete.${RESET}

Activate the environment:

    source jpamb/.jpamb-eval/bin/activate

JPAMB resolves the benchmark from the current directory, so run analyses from
inside the submodule:

    cd jpamb
    jpamb checkhealth
    jpamb -v analyse python $ASSIGNMENT
EOF

if [ "$INSTALL_SYNTACTIC" -eq 1 ]; then
    cat <<EOF
    jpamb -v analyse syntactic-bytecode   # the reference solution
EOF
fi

if [ "${UV_WAS_INSTALLED:-0}" -eq 1 ]; then
    printf '\n%swarning%s uv was just installed. Restart your shell so it stays on PATH.\n' "$YELLOW" "$RESET"
fi
