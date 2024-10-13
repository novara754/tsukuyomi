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
const ps2 = lib.ps2;
const kbd = lib.kbd;
const logger = lib.logger;
const ata = lib.ata;
const gpt = lib.gpt;
const fat16 = lib.fat16;

export fn _start() noreturn {
    // logger.configure(.{ .maxLevel = .info, .dimInfo = false });

    uart.init() catch {
        spin();
    };
    logger.log(.info, "uart", "initialized", .{});

    if (limine.BASE_REVISION[2] != 0) {
        ppanic("limine base revision has unexpected value ({})", .{limine.BASE_REVISION[2]});
    }

    const hhdm_response = limine.HHDM.response orelse {
        ppanic("limine hhdm response is null", .{});
    };
    logger.log(.debug, "limine", "hhdm offset: {x}", .{hhdm_response.*.offset});

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
    logger.log(.debug, "mem", "number of usable physical pages: {} ({} bytes)", .{ free_pages, free_pages * mem.PAGE_SIZE });

    heap.init();
    logger.log(.info, "kheap", "initialized", .{});

    gdt.loadKernelGDT();
    logger.log(.info, "gdt", "kernel gdt loaded", .{});

    idt.init();
    logger.log(.info, "idt", "initialized", .{});

    const acpi_data = acpi.init(rsdp.rsdp_addr) catch |e| {
        ppanic("failed to parse acpi tables: {}", .{e});
    };

    ioapic.init(acpi_data.madt.ioapic_base);
    logger.log(.info, "ioapic", "initialized", .{});

    lapic.init(acpi_data.madt.lapic_base);
    logger.log(.info, "lapic", "initialized", .{});

    logger.log(.debug, "limine", "modules loaded:", .{});
    for (modules.modules, 0..modules.module_count) |m, i| {
        logger.log(.debug, "limine", "{}. {s}, at={*}, size={}", .{ i, m.path, m.address, m.size });
        lmfs.registerFile(m) catch |e| {
            ppanic("registerFile: {}", .{e});
        };
    }

    if (lmfs.open("//usr/sh")) |file| {
        logger.log(.debug, "proc", "making proc for //usr/sh...", .{});
        procFromFile(file.ref, "sh") catch |e| {
            ppanic("procFromFile: {}", .{e});
        };
    } else {
        ppanic("//usr/sh not found", .{});
    }

    uart.UART1.enableInterrupts();
    logger.log(.debug, "uart", "interrupts enabled for uart1", .{});

    free_pages = mem.PAGE_ALLOCATOR.countFree();
    logger.log(.debug, "mem", "number of usable physical pages: {} ({} bytes)", .{ free_pages, free_pages * mem.PAGE_SIZE });

    logger.log(.debug, "limine", "found {} framebuffers", .{framebuffer.framebuffer_count});
    for (framebuffer.framebuffers[0..framebuffer.framebuffer_count]) |fb| {
        logger.log(.debug, "limine", " - {}x{}, {} bpp, {s}", .{ fb.width, fb.height, fb.bpp, @tagName(fb.memory_model) });
    }

    const font = psf.Font.fromBytes(@embedFile("terminal-font.psf")) catch |e| {
        ppanic("failed to load font: {}", .{e});
    };
    const fb = Framebuffer.fromLimine(framebuffer.framebuffers[0]);
    Terminal.init(fb, font);

    ps2.init() catch |e| {
        ppanic("failed to initialize ps2 controller: {}", .{e});
    };
    logger.log(.info, "ps2", "initialized", .{});

    kbd.init() catch |e| {
        ppanic("kbd: {}", .{e});
    };
    logger.log(.info, "kbd", "initialized", .{});

    ata.ATA0.init(.primary) catch {};
    ata.ATA0.init(.secondary) catch {};
    ata.ATA1.init(.primary) catch {};
    ata.ATA1.init(.secondary) catch {};

    if (!ata.ATA0.valid(.primary)) {
        ppanic("ata0 #0 not accessible", .{});
    }

    const buf = heap.allocator().alignedAlloc(u8, @alignOf(gpt.TableHeader), 512) catch |e| {
        ppanic("failed to allocate buf: {}", .{e});
    };
    defer heap.allocator().free(buf);

    ata.ATA0.readSectors(.primary, 1, 1, buf) catch |e| {
        ppanic("{}", .{e});
    };
    const header: gpt.TableHeader = std.mem.bytesToValue(gpt.TableHeader, buf);
    if (!header.verify()) {
        ppanic("invalid hpt header", .{});
    }

    logger.log(.info, "main", "found gpt table on ata0 #0", .{});

    const partitions = gpt.readPartitions(&header, ata.ATA0.getBlockDevice(.primary), heap.allocator()) catch |e| {
        ppanic("failed to read partitions: {}", .{e});
    };
    defer partitions.deinit();

    const part = gpt.PartitionBlockDevice(ata.BlockDevice){
        .inner = ata.ATA0.getBlockDevice(.primary),
        .layout = partitions.items[0],
    };

    {
        const ebpb = fat16.readEBPB(part, heap.allocator()) catch |e| {
            ppanic("failed to read ebpb: {}", .{e});
        };
        defer heap.allocator().destroy(ebpb);

        const fat = fat16.readFAT(ebpb, part, heap.allocator()) catch |e| {
            ppanic("failed to read fat: {}", .{e});
        };
        defer heap.allocator().free(fat);

        const root_dir = fat16.readRootDir(ebpb, part, heap.allocator()) catch |e| {
            ppanic("failed to read root_dir: {}", .{e});
        };
        defer heap.allocator().free(root_dir);
        for (root_dir[0..10], 0..) |entry, i| {
            if (entry.valid() and entry.attributes != fat16.DirEntryAttribute.vfat) {
                if (entry.extension().len > 0) {
                    logger.log(.debug, "main", "{}. {s}.{s}", .{ i, entry.filename(), entry.extension() });
                } else {
                    logger.log(.debug, "main", "{}. {s}", .{ i, entry.filename() });
                }
            }
        }

        const dir_entry = fat16.findFile("/EFI/BOOT/BOOTX64.EFI", ebpb, part, heap.allocator()) catch |e| {
            ppanic("failed to find file: {}", .{e});
        };
        logger.log(.debug, "main", "entry = {}", .{dir_entry});
        if (dir_entry.extension().len > 0) {
            logger.log(.debug, "main", "{s}.{s}", .{ dir_entry.filename(), dir_entry.extension() });
        } else {
            logger.log(.debug, "main", "{s}", .{dir_entry.filename()});
        }
    }

    logger.log(.info, "proc", "entering scheduler...", .{});
    process.scheduler();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    ppanic("{s}", .{msg});
}

fn procFromFile(file: *const limine.File, name: []const u8) !void {
    const elf = std.elf;

    const ehdr: *const elf.Ehdr = @ptrCast(file.address);

    var proc = try process.allocProcess(name);

    mem.setPML4(proc.pml4);
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

    var tf = proc.trap_frame;
    tf.cs = gdt.SEG_USER_CODE << 3 | 0b11;
    tf.ds = gdt.SEG_USER_DATA << 3 | 0b11;
    tf.es = tf.ds;
    tf.ss = tf.ds;
    tf.rflags = 0x200; // IF
    tf.rsp = process.USER_STACK_BOTTOM + mem.PAGE_SIZE;
    tf.rip = ehdr.e_entry;
    proc.state = process.ProcessState.runnable;
}
