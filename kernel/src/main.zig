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
const process = @import("process.zig");

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

    var mapper = mem.Mapper.forCurrentPML4();
    {
        const virt = @intFromPtr(&_start);
        if (mapper.translate(virt)) |trans| {
            uart.print("_start: virt={x}, phys={?x}, size={s}\n", .{ virt, trans.phys, @tagName(trans.size) });
        } else {
            uart.print("failed to translate _start\n", .{});
        }
    }
    {
        const page = mem.PAGE_ALLOCATOR.alloc();
        const virt = 0xFFFA_0000_0000_0000;
        mapper.map(virt, mem.v2p(page), false);
        uart.print("mapped {x} to {x}\n", .{ virt, mem.v2p(page) });
        if (mapper.translate(virt)) |trans| {
            uart.print("virt={x}, phys={?x}, size={s}\n", .{ virt, trans.phys, @tagName(trans.size) });
        } else {
            uart.print("failed to translate\n", .{});
        }
    }

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

    procFromFunc(@intFromPtr(&proc1), @intFromPtr(&STACK1) + mem.PAGE_SIZE) catch |e| {
        ppanic("failed to create proc1: {}", .{e});
    };
    procFromFunc(@intFromPtr(&proc2), @intFromPtr(&STACK2) + mem.PAGE_SIZE) catch |e| {
        ppanic("failed to create proc2: {}", .{e});
    };

    // process.scheduler();

    uart.print("spinning...\n", .{});
    spin();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    ppanic("{s}", .{msg});
}

fn proc1() noreturn {
    while (true) {
        uart.print("A", .{});
        for (0..1_00_000) |_| {
            // std.mem.doNotOptimizeAway(i);
        }
    }
}

fn proc2() noreturn {
    while (true) {
        uart.print("B", .{});
        for (0..1_00_000) |_| {
            // std.mem.doNotOptimizeAway(i);
        }
    }
}

fn procFromFunc(f: u64, rsp: u64) !void {
    const proc_ = process.allocProcess();
    var proc = proc_ orelse {
        return error.CouldNotAllocateProcess;
    };
    var tf = proc.trap_frame;
    tf.cs = gdt.SEG_KERNEL_CODE << 3;
    tf.ds = gdt.SEG_KERNEL_DATA << 3;
    tf.es = tf.ds;
    tf.ss = tf.ds;
    tf.rflags = 0x200; // IF
    tf.rsp = rsp;
    tf.rip = f;
    proc.state = process.ProcessState.runnable;
}

export var STACK1: [mem.PAGE_SIZE]u8 = undefined;
export var STACK2: [mem.PAGE_SIZE]u8 = undefined;
