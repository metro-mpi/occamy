# Source this inside the date-mmpi-dev-c container before running the Occamy
# Verilator flow. Adapted from native-env.sh for this container's actual tool
# paths (all container-layer installs under /tools, custom Verilator under the
# bind-mounted /workspace/verilator).
unset VERILATOR_ROOT   # the wrapper computes its own; setting this causes a mismatch error

export PATH="/workspace/verilator/bin:/tools/bender:/tools/riscv-cva6/bin:/tools/llvm/bin:$PATH"
export RISCV_GCC_BINROOT="/tools/riscv-cva6/bin"
export LLVM_BINROOT="/tools/llvm/bin"
export BENDER="/tools/bender/bender"
export CXX=mpic++
export CC=gcc

# Container runs as root; mpirun refuses to launch as root without this.
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
