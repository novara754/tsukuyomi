const uart = @import("uart.zig");
const limine = @import("limine.zig");
const spin = @import("x86.zig").spin;
const panic = @import("panic.zig").panic;
const gdt = @import("gdt.zig");

export fn _start() noreturn {
    uart.init() catch {
        spin();
    };
    uart.print("UART initialized.\n", .{});

    if (limine.BASE_REVISION[2] != 0) {
        panic("limine base revision has unexpected value ({})", .{limine.BASE_REVISION[2]});
    }

    const hhdm_response = limine.HHDM.response orelse {
        panic("limine hhdm response is null", .{});
    };

    uart.print("hhdm offset: {x}\n", .{hhdm_response.*.offset});

    gdt.loadKernelGDT();
    uart.print("Kernel GDT initialized.\n", .{});

    uart.print("Spinning...\n", .{});
    spin();
}
