// Bisection test 2: exact offload.c pattern + init_uart() only, no print_uart at all.

#include "host.c"

#define PERIPH_FREQ 1000000000

int main() {
    reset_and_ungate_quadrants();
    deisolate_all();
    enable_sw_interrupts();
    program_snitches();
    asm volatile("" ::: "memory");
    wakeup_snitches_cl();
    int ret = wait_snitches_done();

    init_uart(PERIPH_FREQ, 115200);

    return ret;
}
