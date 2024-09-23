const uart = @import("uart.zig");

export fn _start() void {
    if (!uart.init()) {
        spin();
    }
    uart.puts("hello, world!");
    spin();
}

fn spin() void {
    while (true) {
        asm volatile ("pause");
    }
}
