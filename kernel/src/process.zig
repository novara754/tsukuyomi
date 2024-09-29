const std = @import("std");
const TrapFrame = @import("interrupts/idt.zig").TrapFrame;
const Spinlock = @import("Spinlock.zig");
const mem = @import("mem.zig");
const gdt = @import("gdt.zig");
const vfs = @import("vfs.zig");
const panic = @import("panic.zig").panic;

pub const USER_STACK_BOTTOM = 0x0000_7000_0000_0000;

const MAX_NUM_PROCESSES = 16;

const Context = struct {
    _rbx: u64 = 0,
    _rbp: u64 = 0,
    _r12: u64 = 0,
    _r13: u64 = 0,
    _r14: u64 = 0,
    _r15: u64 = 0,
    rip: u64 = 0,
};

pub const ProcessState = enum {
    unused,
    embryo,
    runnable,
    running,
    zombie,
    sleeping,
};

const Process = struct {
    name: []const u8,
    state: ProcessState,
    pid: u64,
    parent: ?*Process,
    pml4: usize,
    kernel_stack: [*]u8,
    trap_frame: *TrapFrame,
    context: *Context,
    exit_status: u64,
    files: [16]?vfs.File,
    wait_channel: u64,
};

const CPU = struct {
    gdt: [7]u64 = .{ 0, 0, 0, 0, 0, 0, 0 },
    tss: gdt.TSS = .{},
    scheduler_context: *Context = undefined,
    process: ?*Process = null,
};

var NEXT_PID: u64 = 0;
var LOCK = Spinlock{};
pub var PROCESSES: [MAX_NUM_PROCESSES]Process = [1]Process{Process{
    .state = .unused,
    .name = undefined,
    .pid = undefined,
    .parent = undefined,
    .pml4 = undefined,
    .kernel_stack = undefined,
    .trap_frame = undefined,
    .context = undefined,
    .exit_status = undefined,
    .files = undefined,
    .wait_channel = undefined,
}} ** MAX_NUM_PROCESSES;
pub var CPU_STATE = CPU{};

extern fn handleTrapRet() void;

pub fn allocProcess(name: []const u8) !*Process {
    LOCK.acquire();
    defer LOCK.release();

    var p: ?*Process = null;
    for (&PROCESSES) |*it| {
        if (it.state == .unused) {
            p = it;
            break;
        }
    }

    const proc: *Process = p orelse return error.TooManyProcesses;
    proc.state = .embryo;
    proc.name = name;
    proc.pid = @atomicRmw(u64, &NEXT_PID, .Add, 1, .seq_cst);
    proc.parent = null;
    proc.kernel_stack = @ptrCast(mem.PAGE_ALLOCATOR.alloc());

    var sp: usize = @intFromPtr(proc.kernel_stack);
    sp += mem.PAGE_SIZE;

    sp -= @sizeOf(TrapFrame);
    proc.trap_frame = @ptrFromInt(sp);

    sp -= @sizeOf(u64);
    const rip: *u64 = @ptrFromInt(sp);
    rip.* = @intFromPtr(&handleTrapRet);

    sp -= @sizeOf(Context);
    proc.context = @ptrFromInt(sp);
    proc.context.* = Context{};
    proc.context.rip = @intFromPtr(&forkRet);

    proc.files = [1]?vfs.File{null} ** 16;

    return proc;
}

extern fn switchContext(old: **Context, new: *Context) callconv(.SysV) void;

pub fn scheduler() noreturn {
    while (true) {
        asm volatile ("sti");

        LOCK.acquire();
        for (&PROCESSES) |*proc| {
            if (proc.state != ProcessState.runnable) {
                continue;
            }

            proc.state = ProcessState.running;
            CPU_STATE.process = proc;
            CPU_STATE.tss.rsp0 = @intFromPtr(proc.kernel_stack) + mem.PAGE_SIZE;
            gdt.loadGDTWithTSS(&CPU_STATE.gdt, &CPU_STATE.tss);
            mem.setPML4(proc.pml4);
            switchContext(&CPU_STATE.scheduler_context, proc.context);
            mem.restoreKernelPML4();
            gdt.loadKernelGDT();
            CPU_STATE.process = null;
        }
        LOCK.release();
    }
}

pub fn yield() void {
    var proc = CPU_STATE.process orelse {
        panic("yield was called without an active process", .{});
    };

    LOCK.acquire();
    proc.state = ProcessState.runnable;
    switchContext(&proc.context, CPU_STATE.scheduler_context);
    LOCK.release();
}

pub fn doFork() !u64 {
    const this_proc = CPU_STATE.process orelse {
        panic("doFork was called without an active process", .{});
    };

    var new_proc = try allocProcess(this_proc.name);

    const this_pml4: *mem.PageTable = @alignCast(@ptrCast(mem.p2v(this_proc.pml4)));
    const new_pml4: *mem.PageTable = @ptrCast(mem.PAGE_ALLOCATOR.allocZeroed());

    var new_mapper = mem.Mapper.forPML4(new_pml4);

    // copy entries for kernel page mappings
    for (256..512) |i| {
        if (!this_pml4[i].present()) {
            continue;
        }

        new_pml4[i] = this_pml4[i];
    }

    for (this_pml4[0..256], 0..) |*pml4_entry, pml4_idx| {
        if (!pml4_entry.present()) {
            continue;
        }

        const pdpt: *mem.PageTable = @alignCast(@ptrCast(mem.p2v(pml4_entry.frame())));
        for (pdpt, 0..) |*pdpt_entry, pdpt_idx| {
            if (!pdpt_entry.present()) {
                continue;
            }

            if (pdpt_entry.pageSize()) {
                panic("process.fork: pdpt_entry #{} has PS bit set", .{pdpt_idx});
            }

            const pd: *mem.PageTable = @alignCast(@ptrCast(mem.p2v(pdpt_entry.frame())));
            for (pd, 0..) |*pd_entry, pd_idx| {
                if (!pd_entry.present()) {
                    continue;
                }

                if (pd_entry.pageSize()) {
                    panic("process.fork: pd_entry #{} has PS bit set", .{pd_idx});
                }

                const pt: *mem.PageTable = @alignCast(@ptrCast(mem.p2v(pd_entry.frame())));
                for (pt, 0..) |*pt_entry, pt_idx| {
                    if (!pt_entry.present()) {
                        continue;
                    }

                    const this_page: *[mem.PAGE_SIZE]u8 = @alignCast(@ptrCast(mem.p2v(pt_entry.frame())));

                    const virt = (pml4_idx << 39) | (pdpt_idx << 30) | (pd_idx << 21) | (pt_idx << 12);

                    const new_page: *[mem.PAGE_SIZE]u8 = @ptrCast(mem.PAGE_ALLOCATOR.alloc());
                    const new_page_phys = mem.v2p(new_page);
                    new_mapper.map(virt, new_page_phys, .user, .panic);

                    new_page.* = this_page.*;
                }
            }
        }
    }
    const new_stack: *[mem.PAGE_SIZE]u8 = @ptrCast(mem.PAGE_ALLOCATOR.alloc());
    const new_stack_phys = mem.v2p(new_stack);
    new_stack.* = @as(*[mem.PAGE_SIZE]u8, @ptrFromInt(USER_STACK_BOTTOM)).*;
    new_mapper.map(USER_STACK_BOTTOM, new_stack_phys, .user, .overwrite);

    new_proc.parent = this_proc;
    new_proc.pml4 = mem.v2p(new_pml4);
    new_proc.trap_frame.* = this_proc.trap_frame.*;
    // set rax to 0 as the return value of fork for the child
    new_proc.trap_frame.rax = 0;

    for (this_proc.files, 0..) |f, i| {
        new_proc.files[i] = f;
    }

    LOCK.acquire();
    new_proc.state = ProcessState.runnable;
    LOCK.release();

    return new_proc.pid;
}

fn forkRet() void {
    LOCK.release();
}

pub fn doExit(status: u64) noreturn {
    var proc = CPU_STATE.process orelse {
        panic("doExit was called without an active process", .{});
    };
    LOCK.acquire();
    proc.state = ProcessState.zombie;
    proc.exit_status = status;
    if (proc.parent) |parent| {
        awakenWithLock(@intFromPtr(parent));
    }
    @import("uart.zig").print("process {s} exited with status {}\n", .{ proc.name, status });
    switchContext(&proc.context, CPU_STATE.scheduler_context);
    panic("switchContext returned to doExit", .{});
}

pub fn addOpenFile(proc: *Process, file: vfs.File) !u64 {
    for (&proc.files, 0..) |*open_file, i| {
        if (open_file.* == null) {
            open_file.* = file;
            return i;
        }
    }
    return error.TooManyOpenFiles;
}

pub fn sleep(wait_channel: u64, lock: *Spinlock) void {
    var proc = CPU_STATE.process orelse {
        panic("sleep was called without an active process", .{});
    };

    if (lock != &LOCK) {
        LOCK.acquire();
        lock.release();
    }
    proc.wait_channel = wait_channel;
    proc.state = ProcessState.sleeping;
    switchContext(&proc.context, CPU_STATE.scheduler_context);

    proc.wait_channel = 0;

    if (lock != &LOCK) {
        lock.acquire();
        LOCK.release();
    }
}

pub fn awaken(wait_channel: u64) void {
    LOCK.acquire();
    defer LOCK.release();

    awakenWithLock(wait_channel);
}

pub fn awakenWithLock(wait_channel: u64) void {
    for (&PROCESSES) |*proc| {
        if (proc.state == ProcessState.sleeping and proc.wait_channel == wait_channel) {
            proc.state = ProcessState.runnable;
        }
    }
}

pub fn wait() u64 {
    const proc = CPU_STATE.process orelse {
        panic("sleep was called without an active process", .{});
    };

    LOCK.acquire();
    while (true) {
        var has_children = false;
        for (&PROCESSES) |*p| {
            if (p.parent != proc) {
                continue;
            }

            has_children = true;

            if (p.state != ProcessState.zombie) {
                continue;
            }

            // todo: free p's memory
            p.state = ProcessState.unused;
            LOCK.release();
            return p.pid;
        }
        if (has_children) {
            sleep(@intFromPtr(proc), &LOCK);
        } else {
            break;
        }
    }
    LOCK.release();
    return ~@as(u64, 0);
}

pub fn doExec(path: []const u8) !void {
    const proc = CPU_STATE.process orelse {
        panic("exec was called without an active process", .{});
    };

    const elf = std.elf;

    const file = vfs.open(path) orelse return error.NoSuchFile;
    const limine_file = switch (file) {
        .limine => |f| f.ref,
        .uart => return error.NoSuchFile,
    };

    var mapper = mem.Mapper.forCurrentPML4();

    const ehdr: *const elf.Ehdr = @ptrCast(limine_file.address);
    const phdrs: [*]const elf.Elf64_Phdr = @alignCast(@ptrCast(&limine_file.address[ehdr.e_phoff]));
    for (phdrs[0..ehdr.e_phnum]) |phdr| {
        if (phdr.p_type != elf.PT_LOAD) {
            continue;
        }

        var addr = phdr.p_vaddr;
        const end = phdr.p_vaddr + phdr.p_memsz;
        while (addr < end) : (addr += mem.PAGE_SIZE) {
            const phys = mem.v2p(mem.PAGE_ALLOCATOR.allocZeroed());
            mapper.map(addr, phys, .user, .overwrite);
        }

        const src: [*]u8 = @ptrCast(&limine_file.address[phdr.p_offset]);
        const dst: [*]u8 = @ptrFromInt(phdr.p_vaddr);
        std.mem.copyForwards(u8, dst[0..phdr.p_memsz], src[0..phdr.p_filesz]);
    }

    proc.name = limine_file.pathSlice();
    var tf = proc.trap_frame;
    tf.cs = gdt.SEG_USER_CODE << 3 | 0b11;
    tf.ds = gdt.SEG_USER_DATA << 3 | 0b11;
    tf.es = tf.ds;
    tf.ss = tf.ds;
    tf.rflags = 0x200; // IF
    tf.rsp = USER_STACK_BOTTOM + mem.PAGE_SIZE;
    tf.rip = ehdr.e_entry;
    proc.state = .runnable;
}
