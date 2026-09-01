// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Bisection test 1: exact offload.c pattern, adding ONLY init_uart() before
// the quadrant reset/wakeup sequence (matching hello_world's own ordering)
// and print_uart() after wait_snitches_done() returns.

#include "host.c"

#define PERIPH_FREQ 1000000000

int main() {
    init_uart(PERIPH_FREQ, 115200);
    asm volatile("fence" : : : "memory");

    // Reset and ungate all quadrants, deisolate
    reset_and_ungate_quadrants();
    deisolate_all();

    // Enable interrupts to receive notice of job termination
    enable_sw_interrupts();

    // Program Snitch entry point and communication buffer
    program_snitches();

    // Compiler fence to ensure Snitch entry point is
    // programmed before Snitches are woken up
    asm volatile("" ::: "memory");

    // Start Snitches
    wakeup_snitches_cl();

    // Wait for job done and return Snitch exit code
    int ret = wait_snitches_done();

    print_uart(ret == 0 ? "bisect1: PASS\r\n" : "bisect1: FAIL\r\n");
    return ret;
}
