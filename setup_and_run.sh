#!/bin/bash
# Usage: setup_and_run.sh <copy_dir> <cfg_name> <n_quadrants> <n_clusters_per_quad> <n_ranks>
set -x
COPY_DIR=$1
CFG_NAME=$2
NQ=$3
NC=$4
NRANKS=$5
OCCAMY=$COPY_DIR
SIM=$COPY_DIR/target/sim
export PATH=/workspace/verilator/bin:$PATH

# Metro-MPI's --mmpi-in requires every partition instance to share one parent
# module scope. Cluster-axis configs (NQ==1) partition at the cluster level
# (siblings under one quadrant); quadrant-axis configs (NQ>1) must instead
# partition at the quadrant level (siblings under the single SoC), since
# clusters in different quadrants have different parents. The generated
# partition module/binary name differs accordingly.
if [ "$NQ" -gt 1 ]; then
  PARTITION_MODULE=occamy_quadrant_s1
else
  PARTITION_MODULE=occamy_cluster_wrapper
fi

cd $SIM

# --- cfg file (if not already present) ---
if [ ! -f cfg/${CFG_NAME}.hjson ]; then
  cp cfg/mmpi-1x4.hjson cfg/${CFG_NAME}.hjson
  sed -i "s/nr_s1_quadrant: 1,/nr_s1_quadrant: ${NQ},/; s/nr_clusters: 4,/nr_clusters: ${NC},/" cfg/${CFG_NAME}.hjson
fi

# --- sw_spec.json (rank -> instance mapping) ---
# Metro-MPI's --mmpi-in requires every selected partition instance to share
# ONE parent module scope ("Current MMPI generation supports one parent
# module per run"). For the cluster axis (nq==1), the clusters all share the
# single quadrant as parent -- fine to target them individually. For the
# quadrant axis (nq>1, nc==1), individual clusters live under DIFFERENT
# quadrant parents, so we must partition at the quadrant module itself
# instead (all quadrants share the single i_occamy_soc parent).
python3 -c "
import json
nq = $NQ
nc = $NC
ranks = []
rank = 1
if nq > 1:
    for q in range(nq):
        ranks.append({'rank': rank, 'instances': [f'\$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_{q}']})
        rank += 1
else:
    for q in range(nq):
        for c in range(nc):
            ranks.append({'rank': rank, 'instances': [f'\$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_{q}.i_occamy_cluster_{c}']})
            rank += 1
spec = {'schema_version': 2, 'rank0': 'system', 'ranks': ranks}
with open('sw_spec_${CFG_NAME#mmpi-}.json', 'w') as f:
    json.dump(spec, f, indent=2)
"

ensure_rtl_generated() {
  for attempt in 1 2 3 4 5; do
    if [ -s src/occamy_soc.sv ] && [ -s src/occamy_top.sv ] && [ -s src/occamy_pkg.sv ] \
       && [ -s src/occamy_quadrant_s1.sv ] && [ -s src/occamy_cluster_wrapper.sv ]; then
      echo "RTL_VERIFIED: all core .sv files present (attempt $attempt)"
      return 0
    fi
    echo "RTL_MISSING_FILES: retry $attempt regenerating RTL for ${CFG_NAME}"
    rm -f cfg/lru.hjson
    make -C $SIM BENDER=/tools/bender/bender VLT=/workspace/verilator/bin/verilator \
      VERIBLE_FMT=true CFG_OVERRIDE=cfg/${CFG_NAME}.hjson rtl
  done
  echo "RTL_GENERATION_FAILED: giving up after 5 attempts"
  return 1
}

ensure_binary() {
  # Usage: ensure_binary <path> <rebuild-cmd...>
  local target=$1; shift
  for attempt in 1 2 3; do
    if [ -s "$target" ]; then
      echo "BINARY_VERIFIED: $target present (attempt $attempt)"
      return 0
    fi
    echo "BINARY_MISSING: retry $attempt for $target"
    "$@"
  done
  echo "BINARY_BUILD_FAILED: giving up on $target after 3 attempts"
  return 1
}

echo "=== STEP 1: baseline RTL build ($CFG_NAME) ==="
if [ -s bin/occamy_top.vlt ]; then
  echo "BINARY_ALREADY_PRESENT: bin/occamy_top.vlt exists, skipping rebuild"
else
  rm -rf work-vlt
  make -C $OCCAMY -f Makefile.occamy default-build \
    GSOC=/workspace OCCAMY=$OCCAMY \
    VLT=/workspace/verilator/bin/verilator BENDER=/tools/bender/bender VENV_BIN=/usr/bin \
    DEFAULT_CFG=cfg/${CFG_NAME}.hjson
  echo "BASELINE_BUILD_EXIT=$?"

  ensure_rtl_generated || { echo "=== $CFG_NAME ABORTED: RTL generation failed ==="; exit 1; }

  echo "=== STEP 1b: ensure baseline binary exists ==="
  ensure_binary bin/occamy_top.vlt \
    make -C $SIM BENDER=/tools/bender/bender VLT=/workspace/verilator/bin/verilator \
      VERIBLE_FMT=true CFG_OVERRIDE=cfg/${CFG_NAME}.hjson VLT_JOBS=4 \
      CFG_CXXFLAGS_PCH="-c -x c++-header" bin/occamy_top.vlt \
    || { echo "=== $CFG_NAME ABORTED: baseline binary build failed ==="; exit 1; }
fi

echo "=== STEP 2: regenerate ALL platform headers + libsnRuntime.a ==="
# Full PLATFORM_HEADERS list from target/sim/Makefile (occamy_cfg.h,
# occamy_base_addr.h, clint.h, occamy_soc_ctrl.h, snitch_cluster_peripheral.h,
# snitch_quad_peripheral.h, snitch_hbm_xbar_peripheral.h, idma.h). Delete ONLY
# these regenerated targets by name -- NOT a *.h wildcard, since the same
# directory also holds static, checked-in support headers (sys_dma.h,
# uart.h, bitfield.h, fpu_util.h, tlb.h) that no Makefile rule regenerates;
# wiping those with a wildcard breaks every subsequent build permanently.
rm -f sw/shared/platform/generated/occamy_cfg.h \
  sw/shared/platform/generated/occamy_base_addr.h \
  sw/shared/platform/generated/clint.h \
  sw/shared/platform/generated/occamy_soc_ctrl.h \
  sw/shared/platform/generated/snitch_cluster_peripheral.h \
  sw/shared/platform/generated/snitch_quad_peripheral.h \
  sw/shared/platform/generated/snitch_hbm_xbar_peripheral.h \
  sw/shared/platform/generated/idma.h
make BENDER=/tools/bender/bender VLT=/workspace/verilator/bin/verilator \
  sw/shared/platform/generated/occamy_cfg.h \
  sw/shared/platform/generated/occamy_base_addr.h \
  sw/shared/platform/generated/clint.h \
  sw/shared/platform/generated/occamy_soc_ctrl.h \
  sw/shared/platform/generated/snitch_cluster_peripheral.h \
  sw/shared/platform/generated/snitch_quad_peripheral.h \
  sw/shared/platform/generated/snitch_hbm_xbar_peripheral.h \
  sw/shared/platform/generated/idma.h
ls -la sw/shared/platform/generated/*.h
cd sw/device/runtime
rm -f build/libsnRuntime.a
make
cd $SIM

echo "=== STEP 3: rebuild reduce device+host software ==="
cd sw/device/apps/reduce
rm -f build/reduce.elf build/reduce.bin build/origin.ld
cd $SIM/sw/host/apps/offload
rm -rf build
make partial-build
cd $SIM/sw/device/apps/reduce
make
cd $SIM/sw/host/apps/offload
make $SIM/sw/host/apps/offload/build/offload-reduce.elf
cd $SIM

echo "=== STEP 4: baseline run ($CFG_NAME) ==="
rm -f uart0.log; rm -rf logs
( time ./bin/occamy_top.vlt sw/host/apps/offload/build/offload-reduce.elf ; echo "EXIT=$?" )
echo "HART_COUNT=$(ls logs/trace_hart_*.dasm 2>/dev/null | wc -l)"

echo "=== STEP 5: partitioned build ($CFG_NAME, partition module=$PARTITION_MODULE) ==="
cp sw_spec_${CFG_NAME#mmpi-}.json sw_spec.json

PARTITION_BINARY=work-mmpi-sw-import/metro_mpi/obj_dir_lib/V${PARTITION_MODULE}

build_manual_hello() {
  # Inlined equivalent of Makefile.occamy's manual-hello-import + -build,
  # parameterized on $PARTITION_MODULE (that target hardcodes
  # occamy_cluster_wrapper, which only works for cluster-axis configs).
  local WARN="-Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC -Wno-ALWCOMBORDER -Wno-SYMRSVDWORD -Wno-LATCH -Wno-COMBDLY -Wno-SHORTREAL -Wno-fatal"
  local VLT_ROOT=$(/workspace/verilator/bin/verilator --getenv VERILATOR_ROOT 2>/dev/null | awk 'NF{line=$0} END{print line}')
  local TB_DIR=$(find $OCCAMY/.bender/git/checkouts -path '*/target/common/test' -type d | head -n 1)
  local TB_BIN=$TB_DIR/tb_bin.cc
  local RANK0_TB_MAIN=$OCCAMY/rank0_tb_main.cc

  test -f "$SIM/sw_spec.json" || return 1
  mkdir -p "$SIM/work-mmpi-sw-import"
  cd "$SIM/work-mmpi-sw-import"
  /workspace/verilator/bin/verilator --cc --mmpi-o1 --d1 --mmpi-in ../sw_spec.json \
      --top-module testharness -exe "$TB_BIN" -f ../work-vlt/files \
      --timing --unroll-count 1024 --Mdir Vmdir $WARN \
      2>&1 | tee import.log
  test "${PIPESTATUS[0]}" -eq 0 || { cd $SIM; return 1; }

  /workspace/verilator/bin/verilator --Mdir Vmdir_sys -f metro_mpi/flist.system $WARN \
      --timing --unroll-count 1024 --cc --top-module testharness
  make -C Vmdir_sys -j6 -f Vtestharness.mk \
      CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium OBJCACHE= \
      CFG_CXXFLAGS_PCH="-c -x c++-header"
  mpic++ -std=gnu++20 -fcoroutines -pthread \
      -I Vmdir_sys -I "$VLT_ROOT/include" -I "$VLT_ROOT/include/vltstd" \
      -I ../work-vlt/riscv-isa-sim/include -I "$TB_DIR" \
      -I ../test -I ../test/uartdpi -I metro_mpi \
      -c "$TB_DIR/verilator_lib.cc" -o verilator_lib.o
  mpic++ -std=gnu++20 -fcoroutines -pthread \
      -I Vmdir_sys -I "$VLT_ROOT/include" -I "$VLT_ROOT/include/vltstd" \
      -I ../work-vlt/riscv-isa-sim/include -I "$TB_DIR" \
      -I ../test -I ../test/uartdpi -I metro_mpi \
      -c "$RANK0_TB_MAIN" -o rank0_tb_main.o
  mpic++ -std=gnu++20 -fcoroutines -pthread \
      -I Vmdir_sys -I "$VLT_ROOT/include" -I "$VLT_ROOT/include/vltstd" \
      -I ../work-vlt/riscv-isa-sim/include -I "$TB_DIR" \
      -I ../test -I ../test/uartdpi -I metro_mpi \
      -c metro_mpi/metro_mpi.cpp -o metro_mpi.o
  mkdir -p bin
  mpic++ -std=gnu++20 -L ../work-vlt/lib -o bin/occamy_top.mpi.vlt \
      rank0_tb_main.o verilator_lib.o metro_mpi.o \
      ../work-vlt/tb/common_lib.o ../work-vlt/tb/ipc.o ../work-vlt/tb/bootrom.o \
      ../work-vlt/tb/bootdata.o ../work-vlt/tb/uartdpi.o \
      ../work-vlt/vlt/verilated.o ../work-vlt/vlt/verilated_dpi.o \
      ../work-vlt/vlt/verilated_threads.o ../work-vlt/vlt/verilated_timing.o \
      ../work-vlt/vlt/verilated_vcd_c.o \
      Vmdir_sys/Vtestharness__ALL.a -lfesvr -lpthread -lsodium

  cd "$SIM/work-mmpi-sw-import/metro_mpi"
  /workspace/verilator/bin/verilator --cc --exe --Mdir obj_dir_lib --top-module $PARTITION_MODULE \
      ${PARTITION_MODULE}_main.cpp metro_mpi.cpp -f flist.library \
      --timing --unroll-count 1024 $WARN \
      -CFLAGS "-I$SIM/work-mmpi-sw-import/metro_mpi -std=gnu++20 -fcoroutines"
  make -C obj_dir_lib -j6 -f V${PARTITION_MODULE}.mk \
      CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium OBJCACHE= \
      CFG_CXXFLAGS_PCH="-c -x c++-header"
  cd $SIM
}

if [ -s work-mmpi-sw-import/bin/occamy_top.mpi.vlt ] && [ -s "$PARTITION_BINARY" ]; then
  echo "PARTITIONED_BINARIES_ALREADY_PRESENT: skipping rebuild"
else
  rm -rf work-mmpi-sw-import
  build_manual_hello
  echo "PARTITIONED_BUILD_EXIT=$?"

  ensure_binary work-mmpi-sw-import/bin/occamy_top.mpi.vlt build_manual_hello \
    || { echo "=== $CFG_NAME ABORTED: partitioned rank0 binary build failed ==="; exit 1; }
fi

ensure_binary "$PARTITION_BINARY" build_manual_hello \
  || { echo "=== $CFG_NAME ABORTED: partitioned $PARTITION_MODULE binary build failed ==="; exit 1; }

echo "=== STEP 6: partitioned run ($CFG_NAME, $NRANKS ranks) ==="
CLUSTER_ARGS=""
for i in $(seq 1 $NRANKS); do
  CLUSTER_ARGS="$CLUSTER_ARGS : -np 1 $PARTITION_BINARY"
done
rm -f uart0.log
( time mpirun --allow-run-as-root --bind-to core --map-by core \
    -np 1 work-mmpi-sw-import/bin/occamy_top.mpi.vlt sw/host/apps/offload/build/offload-reduce.elf \
    $CLUSTER_ARGS \
  ; echo "EXIT=$?" )

echo "=== $CFG_NAME SWEEP COMPLETE ==="
