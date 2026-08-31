# Source this before running the native Occamy Verilator flow on this Linux host.
# Mirrors the Docker /etc/profile.d/devenv.sh but points at host-local installs.
GSOC=/home/kislay/Documents/gsoc

# Custom MPI Verilator (do NOT export VERILATOR_ROOT — the wrapper computes its own)
export PATH="$GSOC/verilator-dev/verilator-private/bin:$PATH"

# Bender + Python venv (occamygen/regtool deps)
export PATH="$GSOC/.codex-tools/bin:$GSOC/.codex-venvs/occamy/bin:$PATH"

# RISC-V CVA6 host toolchain (SiFive GCC) — needed to build host SW + bootrom
if [ -d "$GSOC/.native-tools/riscv-cva6/bin" ]; then
    export RISCV_GCC_BINROOT="$GSOC/.native-tools/riscv-cva6/bin"
    export PATH="$RISCV_GCC_BINROOT:$PATH"
fi

# Snitch device toolchain (pulp LLVM) — needed for device/offload SW
if [ -d "$GSOC/.native-tools/llvm/bin" ]; then
    export LLVM_BINROOT="$GSOC/.native-tools/llvm/bin"
    export PATH="$LLVM_BINROOT:$PATH"
fi

# Bender works against the occamy repo
export BENDER="$GSOC/.codex-tools/bin/bender"

# The fork is built CXX=mpic++; keep TB objects + verilator --build + final link
# on mpic++ so MPI/sodium symbols in the verilated archive resolve. uartdpi.c is C.
export CXX=mpic++
export CC=gcc
