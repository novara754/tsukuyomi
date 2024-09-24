const std = @import("std");

const uart = @import("uart.zig");
const limine = @import("limine.zig");
const spin = @import("x86.zig").spin;
const ppanic = @import("panic.zig").panic;
const gdt = @import("gdt.zig");
const mem = @import("mem.zig");
const acpi = @import("acpi.zig");
const idt = @import("interrupts/idt.zig");
const ioapic = @import("interrupts/ioapic.zig");
const lapic = @import("interrupts/lapic.zig");

export fn _start() noreturn {
    uart.init() catch {
        spin();
    };
    uart.print("uart initialized\n", .{});

    if (limine.BASE_REVISION[2] != 0) {
        ppanic("limine base revision has unexpected value ({})", .{limine.BASE_REVISION[2]});
    }

    const hhdm_response = limine.HHDM.response orelse {
        ppanic("limine hhdm response is null", .{});
    };
    uart.print("hhdm offset: {x}\n", .{hhdm_response.*.offset});

    const memory_map = limine.MEMORY_MAP.response orelse {
        ppanic("limine memory map response is null", .{});
    };

    const rsdp = limine.RSDP.response orelse {
        ppanic("limine rsdp response is null", .{});
    };

    mem.init(@intCast(hhdm_response.*.offset), memory_map);
    const free_pages = mem.PAGE_ALLOCATOR.count_free();
    uart.print("number of usable physical pages: {} ({} bytes)\n", .{ free_pages, free_pages * mem.PAGE_SIZE });

    gdt.loadKernelGDT();
    uart.print("kernel gdt initialized\n", .{});

    idt.init();
    uart.print("idt initialized\n", .{});

    const acpi_data = acpi.init(rsdp.rsdp_addr) catch |e| {
        ppanic("failed to parse acpi tables: {}", .{e});
    };
    uart.print("acpi_data = {}\n", .{acpi_data});

    ioapic.init(acpi_data.madt.ioapic_base);
    uart.print("ioapic initialized\n", .{});

    lapic.init(acpi_data.madt.lapic_base);
    uart.print("lapic initialized\n", .{});
    uart.print("lapic id: {}\n", .{lapic.id()});

    asm volatile ("sti");
    uart.print("spinning...\n", .{});
    spin();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    ppanic("{s}", .{msg});
}
