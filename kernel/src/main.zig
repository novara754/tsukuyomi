const std = @import("std");
const lib = @import("lib.zig");

const uart = lib.uart;
const limine = lib.limine;
const spin = lib.spin;
const ppanic = lib.ppanic;
const gdt = lib.gdt;
const mem = lib.mem;
const heap = lib.heap;
const acpi = lib.acpi;
const idt = lib.idt;
const ioapic = lib.ioapic;
const lapic = lib.lapic;
const process = lib.process;
const lmfs = lib.lmfs;
const psf = lib.psf;
const Terminal = lib.Terminal;
const Framebuffer = lib.Framebuffer;

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

    const framebuffer = limine.FRAMEBUFFER.response orelse {
        ppanic("limine framebuffer response is null", .{});
    };

    mem.init(@intCast(hhdm_response.*.offset), memory_map);
    var free_pages = mem.PAGE_ALLOCATOR.countFree();
    uart.print("number of usable physical pages: {} ({} bytes)\n", .{ free_pages, free_pages * mem.PAGE_SIZE });

    heap.init();
    uart.print("kernel heap initialized\n", .{});

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
        lmfs.registerFile(m) catch |e| {
            ppanic("registerFile: {}", .{e});
        };
    }

    if (lmfs.open("//usr/sh")) |file| {
        uart.print("making proc for //usr/sh...\n", .{});
        procFromFile(file.ref, "sh") catch |e| {
            ppanic("procFromFile: {}", .{e});
        };
    } else {
        ppanic("//usr/sh not found", .{});
    }

    uart.UART1.enableInterrupts();
    uart.print("uart1 interrupts enabled\n", .{});

    free_pages = mem.PAGE_ALLOCATOR.countFree();
    uart.print("number of usable physical pages: {} ({} bytes)\n", .{ free_pages, free_pages * mem.PAGE_SIZE });

    uart.print("found {} framebuffers:\n", .{framebuffer.framebuffer_count});
    for (framebuffer.framebuffers[0..framebuffer.framebuffer_count]) |fb| {
        uart.print(" - {}x{}, {} bpp, {s}\n", .{ fb.width, fb.height, fb.bpp, @tagName(fb.memory_model) });
    }

    // const font = psf.Font.fromBytes(@embedFile("terminal-font.psf")) catch |e| {
    //     ppanic("failed to load font: {}", .{e});
    // };
    // const fb = Framebuffer.fromLimine(framebuffer.framebuffers[0]);
    // var terminal = Terminal.new(fb, font);

    @import("ps2.zig").init() catch |e| {
        ppanic("failed to initialize ps2 controller: {}", .{e});
    };

    @import("kbd.zig").init() catch |e| {
        ppanic("kbd: {}", .{e});
    };

    asm volatile ("sti");
    spin();
    // process.scheduler();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    ppanic("{s}", .{msg});
}

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
            proc_mapper.map(addr, phys, .user, .panic);
        }

        const src: [*]u8 = @ptrCast(&file.address[phdr.p_offset]);
        const dst: [*]u8 = @ptrFromInt(phdr.p_vaddr);
        std.mem.copyForwards(u8, dst[0..phdr.p_memsz], src[0..phdr.p_filesz]);
    }
    const proc_stack_phys = mem.v2p(mem.PAGE_ALLOCATOR.alloc());
    proc_mapper.map(process.USER_STACK_BOTTOM, proc_stack_phys, .user, .panic);
    mem.restoreKernelPML4();

    var proc = try process.allocProcess(name);
    var tf = proc.trap_frame;
    tf.cs = gdt.SEG_USER_CODE << 3 | 0b11;
    tf.ds = gdt.SEG_USER_DATA << 3 | 0b11;
    tf.es = tf.ds;
    tf.ss = tf.ds;
    tf.rflags = 0x200; // IF
    tf.rsp = process.USER_STACK_BOTTOM + mem.PAGE_SIZE;
    tf.rip = ehdr.e_entry;
    proc.state = process.ProcessState.runnable;
    proc.pml4 = mem.v2p(proc_pml4);
}
