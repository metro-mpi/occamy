// Bisection test 3: print before AND after quadrant reset/deisolate only
// (no Snitch launch, no interrupt wait at all), to isolate whether quadrant
// operations alone break UART transmit, independent of Snitch/interrupts.

#include "host.c"

#define PERIPH_FREQ 1000000000

int main() {
    init_uart(PERIPH_FREQ, 115200);
    asm volatile("fence" : : : "memory");
    print_uart("bisect3: before quadrant ops\r\n");

    reset_and_ungate_quadrants();
    deisolate_all();

    print_uart("bisect3: after quadrant ops\r\n");

    for (int i = 0; i < 5000; i++) asm volatile("nop" : : : "memory");
    return 0;
}
