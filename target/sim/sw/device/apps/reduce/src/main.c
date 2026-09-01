// Minimal cross-cluster compute+reduce workload.
//
// Each cluster's hart 0 does WORK_PER_HART independent scalar-add operations
// (deterministic per-cluster busy work), writes its partial result into a
// plain global array (which the linker places in shared L3 per
// snRuntime/base.ld -- .data/.bss both go >L3, not cluster-local TCDM, so
// this is genuinely visible across all clusters), then every hart in every
// cluster participates in a single snrt_global_barrier(). After the
// barrier, global hart 0 checks each cluster's partial against its
// individually-known expected value (not just the aggregate sum, which
// could in principle mask one cluster silently failing to run while
// another's error happens to compensate) and returns the COUNT of clusters
// that produced the correct value. That count reaches the outer shell
// directly as the simulator process's own exit code ($?) via
// snrt_exit()->HTIF->fesvr, the same channel already proven not to hang --
// so `$? == cluster_num` is a direct, per-partition confirmation that every
// rank actually executed its share of the work, without relying on UART.

#include "snrt.h"

#define WORK_PER_HART 500
#define NUM_CLUSTERS_MAX 32

volatile uint32_t partial_sums[NUM_CLUSTERS_MAX] = {0};

// Results published for the host to read and print (device-side printf is a
// no-op in this runtime -- occamy_device's _putchar() is stubbed empty --
// so results must be handed back via the comm_buffer's usr_data_ptr, the
// same mechanism host.c uses to locate device-shared data).
typedef struct {
    uint32_t total;
    uint32_t expected;
    uint32_t pass;
    uint32_t correct_clusters;  // how many clusters individually matched
    uint32_t cluster_num;
} reduce_result_t;

volatile reduce_result_t reduce_result;

int main() {
    uint32_t cluster_id = snrt_cluster_idx();
    uint32_t cluster_num = snrt_cluster_num();
    uint32_t cluster_core_id = snrt_cluster_core_idx();

    if (cluster_core_id == 0) {
        uint32_t partial = 0;
        for (uint32_t i = 0; i < WORK_PER_HART; i++) {
            partial += (cluster_id + 1);
        }
        partial_sums[cluster_id] = partial;
    }

    // Called by every hart in every cluster -- real cross-cluster
    // synchronization (atomic counter + spin-wait in shared memory).
    snrt_global_barrier();

    if (snrt_global_core_idx() == 0) {
        uint32_t total = 0;
        uint32_t correct_clusters = 0;
        for (uint32_t i = 0; i < cluster_num; i++) {
            uint32_t expected_i = WORK_PER_HART * (i + 1);
            if (partial_sums[i] == expected_i) correct_clusters++;
            total += partial_sums[i];
        }
        uint32_t expected = WORK_PER_HART * cluster_num * (cluster_num + 1) / 2;
        uint32_t pass = (total == expected) && (correct_clusters == cluster_num);

        reduce_result.total = total;
        reduce_result.expected = expected;
        reduce_result.pass = pass;
        reduce_result.correct_clusters = correct_clusters;
        reduce_result.cluster_num = cluster_num;
        get_communication_buffer()->usr_data_ptr =
            (uint32_t)(uintptr_t)&reduce_result;

        // Exit code = number of clusters individually verified correct.
        // cluster_num is capped at 32 in this sweep, well within the
        // 8-bit range a process exit code preserves.
        return (int)correct_clusters;
    }
    return 0;
}
