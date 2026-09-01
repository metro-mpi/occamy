// Copyright 2026, GSoC Metro-MPI investigation.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Launches the "reduce" device kernel (cross-cluster compute + real
// snrt_global_barrier() synchronization) and prints its result over UART,
// since device-side printf is a no-op in this runtime (occamy_device's
// _putchar() is stubbed empty). The device publishes a result struct via
// comm_buffer.usr_data_ptr (see sw/device/apps/reduce/src/main.c).
//
// NOTE (corrected during testing on this repo's mmpi-1x4 build): the
// original version of this file hand-rolled its own completion wait as a
// busy-poll on sw_interrupt_pending() instead of using host.c's
// wait_snitches_done() (which waits via wfi()), reasoning that an earlier
// bisection had found UART transmit hangs specifically after a wfi-based
// wait. Testing here initially seemed to confirm a hang (no output after
// 120s with either wait style) -- but a longer run proved that was a false
// positive: this build's UART DPI model is genuinely real-time-baud-rate
// accurate (115200 baud simulated cycle-by-cycle against a 1GHz core), so
// even a short UART string takes several real minutes of wall-clock time to
// fully transmit in RTL simulation, independent of which wait mechanism is
// used or whether Snitch is involved at all (confirmed: even the
// completely unmodified upstream `hello_world`, which never touches
// wait_snitches_done() or sw_interrupt_pending(), took several minutes to
// print "Hello world!" here). So there was no wait-mechanism bug -- this
// version still calls wait_snitches_done() (simpler and more efficient than
// a busy-poll, and proven correct via offload.c throughout this repo, see
// README.md SS4/5), but the actual, real bug fixed here is separate: the
// original compared the return value (reduce.c's exit code, the COUNT of
// clusters that verified correct, e.g. 4 for a fully-passing mmpi-1x4 run)
// against 0 to decide PASS/FAIL -- backwards, since 0 is the worst case (no
// cluster passed), not success. This version prints the actual count
// instead of guessing a threshold it doesn't have enough context (total
// cluster count) to apply correctly from the host side. Give this several
// minutes to complete; it is not hung.

#include "host.c"

#define PERIPH_FREQ 1000000000

static void print_uart_hex_nibble(uint32_t v) {
    char c = (v < 10) ? ('0' + v) : ('a' + (v - 10));
    char s[2] = {c, '\0'};
    print_uart(s);
}

int main() {
    reset_and_ungate_quadrants();
    deisolate_all();
    enable_sw_interrupts();
    program_snitches();
    asm volatile("" ::: "memory");
    wakeup_snitches_cl();
    int ret = wait_snitches_done();

    init_uart(PERIPH_FREQ, 115200);
    asm volatile("fence" : : : "memory");
    print_uart("reduce: correct_clusters=");
    if (ret < 0) {
        print_uart("(error)\r\n");
    } else {
        // ret is small (<=32 per reduce.c's NUM_CLUSTERS_MAX) -- two hex
        // nibbles is plenty and avoids needing a full itoa().
        print_uart_hex_nibble((ret >> 4) & 0xf);
        print_uart_hex_nibble(ret & 0xf);
        print_uart("\r\n");
    }

    for (int i = 0; i < 5000; i++) asm volatile("nop" : : : "memory");
    return ret;
}
