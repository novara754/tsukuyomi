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

    const modules = limine.MODULES.response orelse {
        ppanic("limine modules response is null", .{});
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

    uart.print("modules loaded:\n", .{});
    for (modules.modules, 0..modules.module_count) |m, i| {
        uart.print(" {}. {s}, at={*}, size={}\n", .{ i, m.path, m.address, m.size });
        const path_len = std.mem.len(m.path);
        if (std.mem.eql(u8, m.path[0..path_len], "//usr/hello")) {
            uart.print("making proc for //usr/hello...\n", .{});
            procFromFile(m, "hello1") catch |e| {
                ppanic("procFromFile: {}", .{e});
            };
            procFromFile(m, "hello2") catch |e| {
                ppanic("procFromFile: {}", .{e});
            };
        }
    }

    process.scheduler();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    ppanic("{s}", .{msg});
}

const USER_STACK_BOTTOM = 0x0000_7000_0000_0000;

fn procFromFile(file: *const limine.File, name: []const u8) !void {
    const elf = std.elf;

    const ehdr: *const elf.Ehdr = @ptrCast(file.address);

    const proc_pml4 = mem.createPML4();
    mem.setPML4(mem.v2p(proc_pml4));
    var proc_mapper = mem.Mapper.forCurrentPML4();
    const phdrs: [*]const elf.Elf64_Phdr = @alignCast(@ptrCast(&file.address[ehdr.e_phoff]));
    for (phdrs, 0..ehdr.e_phnum) |phdr, _| {
        if (phdr.p_type != elf.PT_LOAD) {
            continue;
        }

        var addr = phdr.p_vaddr;
        const end = phdr.p_vaddr + phdr.p_memsz;
        while (addr < end) : (addr += mem.PAGE_SIZE) {
            const phys = mem.v2p(mem.PAGE_ALLOCATOR.allocZeroed());
            proc_mapper.map(addr, phys, true);
        }

        const src: [*]u8 = @ptrCast(&file.address[phdr.p_offset]);
        const dst: [*]u8 = @ptrFromInt(phdr.p_vaddr);
        std.mem.copyForwards(u8, dst[0..phdr.p_memsz], src[0..phdr.p_filesz]);
    }
    const proc_stack_phys = mem.v2p(mem.PAGE_ALLOCATOR.alloc());
    proc_mapper.map(USER_STACK_BOTTOM, proc_stack_phys, true);
    mem.restoreKernelPML4();

    const proc_ = process.allocProcess(name);
    var proc = proc_ orelse {
        return error.CouldNotAllocateProcess;
    };
    var tf = proc.trap_frame;
    tf.cs = gdt.SEG_USER_CODE << 3 | 0b11;
    tf.ds = gdt.SEG_USER_DATA << 3 | 0b11;
    tf.es = tf.ds;
    tf.ss = tf.ds;
    tf.rflags = 0x200; // IF
    tf.rsp = USER_STACK_BOTTOM + mem.PAGE_SIZE;
    tf.rip = ehdr.e_entry;
    proc.state = process.ProcessState.runnable;
    proc.pml4 = mem.v2p(proc_pml4);
}
