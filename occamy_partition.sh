#!/usr/bin/env bash
# occamy_partition.sh — Run Metro-MPI partition analysis on Occamy.
#
# Invokes the custom Verilator with `--cc --build --mmpi-o1 --d1` against the
# Occamy testharness. The analysis runs early in Verilator's pipeline and
# exits immediately (it does NOT compile a simulator); its output is a
# `metro_mpi/` directory full of partition reports + auto-generated source
# files. Verilator creates that directory **relative to its CWD**, so this
# script runs from a fresh subdir (`work-vlt-partition/`) to keep the
# existing `work-vlt/` simulator build untouched.
#
# Prerequisites:
#   1. The Docker container is set up and running (see OCCAMY_SETUP.md).
#   2. Occamy's RTL has been generated at least once:
#        cd /workspace/occamy/target/sim
#        make CFG_OVERRIDE=cfg/single-cluster.hjson rtl
#      (We re-run this from the script in case it hasn't.)
#
# Outputs (inside /workspace/occamy/target/sim/work-vlt-partition/):
#   - partition.log                         Full Verilator stdout
#   - metro_mpi/partition_report.json       JSON port-level report
#   - metro_mpi/view_json.py                Pretty-printer for the JSON
#   - metro_mpi/Makefile                    Build recipe for the MPI flow
#   - metro_mpi/flist.{library,system}      Split source file lists
#   - metro_mpi/<wrapper>.v                 One wrapper per partition instance
#   - metro_mpi/modified_<parent>.v         Parent module with wrappers stitched in
#   - metro_mpi/metro_mpi.cpp               MPI verification source
#   - metro_mpi/rank0_harness.h             Rank-0 setup header
#   - metro_mpi/<partition>_main.cpp        Partition-rank main
#   - metro_mpi/README_integration.txt
#
# Usage:
#   bash occamy_partition.sh
#
# Override the Occamy config via CFG_OVERRIDE env var, e.g.
#   CFG_OVERRIDE=cfg/full.hjson bash occamy_partition.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Adapted for this repo's actual container (date-mmpi-dev-c: root user,
# checkout bind-mounted at /workspace/occamy-mmpi, custom Verilator at
# /workspace/verilator/bin) -- originally written against a different,
# older per-project Docker setup (gsoc user, /workspace/occamy).
CONTAINER_NAME="${CONTAINER_NAME:-date-mmpi-dev-c}"
CFG_OVERRIDE="${CFG_OVERRIDE:-cfg/single-cluster.hjson}"

# Sanity: container must be running
if ! docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    echo "Container ${CONTAINER_NAME} is not running. Start it with:" >&2
    echo "    cd /scratch/sws0/user/karya/agentic && make shell" >&2
    exit 1
fi

echo "=== Occamy Metro-MPI partition analysis ==="
echo "Container:    ${CONTAINER_NAME}"
echo "CFG_OVERRIDE: ${CFG_OVERRIDE}"
echo

docker exec -w /workspace/occamy-mmpi/target/sim "${CONTAINER_NAME}" \
    bash -lc "
set -euo pipefail
export PATH=/workspace/verilator/bin:/tools/bender:\$PATH
unset VERILATOR_ROOT

# Verify we have the bender flist; build minimum prereqs if not.
# work-vlt/files is created by the normal vlt build, but if it doesn't
# exist we can generate just the flist + RTL.
if [ ! -f work-vlt/files ]; then
    echo '[occamy_partition] No bender flist yet; generating RTL + flist...'
    make CFG_OVERRIDE='${CFG_OVERRIDE}' rtl
    mkdir -p work-vlt
    bender script verilator -t cv64a6_imafdc_sv39 -t occamy_sim -t snitch_cluster > work-vlt/files
fi

# Fresh output directory; metro_mpi/ will be created here.
OUT_DIR=work-vlt-partition
rm -rf \"\$OUT_DIR\"
mkdir -p \"\$OUT_DIR\"
cd \"\$OUT_DIR\"

# Reuse the existing bender flist (it has absolute paths so it works from anywhere).
FLIST=/workspace/occamy-mmpi/target/sim/work-vlt/files

echo '[occamy_partition] Running verilator with --mmpi-o1 --d1 ...'
echo

# Same Verilator flags as the normal vlt build (occamy/target/sim/Makefile),
# plus the Metro-MPI flags. --d1 triggers exit(0) right after analysis, so
# --cc --build are no-ops here but kept because the user asked for them.
verilator \\
    --cc --build --mmpi-o1 --d1 \\
    --top-module testharness \\
    --Mdir Vmdir \\
    -f \"\$FLIST\" \\
    --timing \\
    --unroll-count 1024 \\
    -Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST \\
    -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT \\
    -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC -Wno-fatal \\
    2>&1 | tee partition.log

echo
echo '=== Outputs in /workspace/occamy-mmpi/target/sim/'\"\$OUT_DIR\"'/ ==='
echo '--- metro_mpi/ contents ---'
ls -la metro_mpi/ 2>/dev/null || echo '(metro_mpi/ not created — analysis may have failed; see partition.log)'
"
