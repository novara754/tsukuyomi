const TrapFrame = @import("interrupts/idt.zig").TrapFrame;
const Spinlock = @import("Spinlock.zig");
const mem = @import("mem.zig");
const gdt = @import("gdt.zig");
const vfs = @import("vfs.zig");
const panic = @import("panic.zig").panic;

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
    .pml4 = undefined,
    .kernel_stack = undefined,
    .trap_frame = undefined,
    .context = undefined,
    .exit_status = undefined,
    .files = undefined,
    .wait_channel = undefined,
}} ** MAX_NUM_PROCESSES;
pub var CPU_STATE = CPU{};

extern fn handle_trap_ret() void;

pub fn allocProcess(name: []const u8) ?*Process {
    LOCK.acquire();
    defer LOCK.release();

    var p: ?*Process = null;
    for (&PROCESSES) |*it| {
        if (it.state == .unused) {
            p = it;
            break;
        }
    }

    const proc: *Process = p orelse return null;
    proc.state = .embryo;
    proc.name = name;
    proc.pid = @atomicRmw(u64, &NEXT_PID, .Add, 1, .seq_cst);
    proc.kernel_stack = @ptrCast(mem.PAGE_ALLOCATOR.alloc());

    var sp: usize = @intFromPtr(proc.kernel_stack);
    sp += mem.PAGE_SIZE;

    sp -= @sizeOf(TrapFrame);
    proc.trap_frame = @ptrFromInt(sp);

    sp -= @sizeOf(u64);
    const rip: *u64 = @ptrFromInt(sp);
    rip.* = @intFromPtr(&handle_trap_ret);

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
        LOCK.release();
        lock.acquire();
    }
}

pub fn awaken(wait_channel: u64) void {
    LOCK.acquire();
    defer LOCK.release();

    for (&PROCESSES) |*proc| {
        if (proc.state == ProcessState.sleeping and proc.wait_channel == wait_channel) {
            proc.state = ProcessState.runnable;
        }
    }
}
