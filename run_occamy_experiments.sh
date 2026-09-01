#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSOC="${GSOC:-$ROOT_DIR}"
OCCAMY_DIR="${OCCAMY_DIR:-$GSOC/occamy}"
MAKEFILE="${MAKEFILE:-$GSOC/Makefile.occamy}"
VLT="${VLT:-$GSOC/verilator-dev/verilator-private/verilator-install/bin/verilator}"
BENDER="${BENDER:-$GSOC/.codex-tools/bin/bender}"
VENV_BIN="${VENV_BIN:-$GSOC/.codex-venvs/occamy/bin}"
BUILD_JOBS="${BUILD_JOBS:-6}"
VLT_JOBS="${VLT_JOBS:-4}"
SMOKE_CYCLES="${SMOKE_CYCLES:-20}"
MPI_CYCLES="${MPI_CYCLES:-20}"
RESET_HARD=0

usage() {
    cat <<USAGE
Usage: $0 [--occamy DIR] [--reset-hard]

Runs the six Occamy experiments one by one:
  1. default-smoke
  2. default-hello
  3. auto-smoke
  4. auto-hello
  5. manual-smoke: --mmpi-out, generated spec.json, --mmpi-in, run
  6. manual-hello: --mmpi-out, generated sw_spec.json, --mmpi-in, run

Environment overrides:
  GSOC, MAKEFILE, VLT, BENDER, VENV_BIN, BUILD_JOBS, VLT_JOBS,
  SMOKE_CYCLES, MPI_CYCLES
USAGE
}

while (($#)); do
    case "$1" in
        --occamy)
            OCCAMY_DIR="$2"
            shift 2
            ;;
        --reset-hard)
            RESET_HARD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

OCCAMY_DIR="$(cd "$OCCAMY_DIR" && pwd)"
SIM_DIR="$OCCAMY_DIR/target/sim"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${LOG_DIR:-$GSOC/occamy-experiment-logs/$(basename "$OCCAMY_DIR")-$RUN_ID}"
SUMMARY="$LOG_DIR/summary.log"
RANK0_TB_MAIN="$LOG_DIR/rank0_tb_main.cc"

mkdir -p "$LOG_DIR"
: > "$SUMMARY"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$SUMMARY"
}

write_rank0_tb_main() {
    cat > "$RANK0_TB_MAIN" <<'CPP'
#include <cstdio>

#include "sim.hh"
#include "rank0_harness.h"

int main(int argc, char **argv, char **env) {
    mpi_initialize();

    FILE *fd = fopen(".rtlbinary", "w");
    if (fd != NULL && argc >= 2) {
        fprintf(fd, "%s\n", argv[1]);
        fclose(fd);
    } else {
        fprintf(stderr, "Warning: Failed to write binary name to .rtlbinary\n");
    }

    auto sim = std::make_unique<sim::Sim>(argc, argv);
    int ret = sim->run();

    metro_mpi_broadcast_shutdown();
    mpi_finalize();
    return ret;
}
CPP
}

write_struct_spec() {
    cat > "$SIM_DIR/spec.json" <<'JSON'
{
  "schema_version": 2,
  "rank0": "system",
  "ranks": [
    {"rank": 1, "instances": ["$root.occamy_quadrant_s1.i_occamy_cluster_0"]},
    {"rank": 2, "instances": ["$root.occamy_quadrant_s1.i_occamy_cluster_1"]},
    {"rank": 3, "instances": ["$root.occamy_quadrant_s1.i_occamy_cluster_2"]},
    {"rank": 4, "instances": ["$root.occamy_quadrant_s1.i_occamy_cluster_3"]}
  ]
}
JSON
}

write_sw_spec() {
    cat > "$SIM_DIR/sw_spec.json" <<'JSON'
{
  "schema_version": 2,
  "rank0": "system",
  "ranks": [
    {"rank": 1, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_0"]},
    {"rank": 2, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_1"]},
    {"rank": 3, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_2"]},
    {"rank": 4, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_3"]}
  ]
}
JSON
}

run_logged() {
    local name="$1"
    shift
    local log_file="$LOG_DIR/${name}.log"

    log "START $name"
    set +e
    "$@" 2>&1 | tee "$log_file"
    local status=${PIPESTATUS[0]}
    set -e
    if [[ "$status" -ne 0 ]]; then
        log "FAIL  $name status=$status log=$log_file"
        exit "$status"
    fi
    log "PASS  $name log=$log_file"
}

run_make() {
    local name="$1"
    shift
    run_logged "$name" make -f "$MAKEFILE" \
        GSOC="$GSOC" OCCAMY="$OCCAMY_DIR" SIM="$SIM_DIR" \
        VLT="$VLT" BENDER="$BENDER" VENV_BIN="$VENV_BIN" \
        RANK0_TB_MAIN="$RANK0_TB_MAIN" \
        BUILD_JOBS="$BUILD_JOBS" VLT_JOBS="$VLT_JOBS" \
        SMOKE_CYCLES="$SMOKE_CYCLES" MPI_CYCLES="$MPI_CYCLES" \
        "$@"
}

if [[ "$RESET_HARD" -eq 1 ]]; then
    run_logged "00-git-reset-hard" git -C "$OCCAMY_DIR" reset --hard
fi

write_rank0_tb_main
log "OCCAMY_DIR=$OCCAMY_DIR"
log "SIM_DIR=$SIM_DIR"
log "MAKEFILE=$MAKEFILE"
log "LOG_DIR=$LOG_DIR"

run_make "01-default-smoke" default-smoke
run_make "02-default-hello" default-hello
run_make "03-auto-smoke" auto-smoke
run_make "04-auto-hello" auto-hello

run_make "05-manual-smoke-export" manual-smoke-export
write_struct_spec
log "WROTE $SIM_DIR/spec.json"
run_make "05-manual-smoke" manual-smoke

run_make "06-manual-hello-export" manual-hello-export
write_sw_spec
log "WROTE $SIM_DIR/sw_spec.json"
run_make "06-manual-hello" manual-hello

log "ALL PASS"
