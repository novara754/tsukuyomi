const TrapFrame = @import("interrupts/idt.zig").TrapFrame;
const Spinlock = @import("Spinlock.zig");
const mem = @import("mem.zig");
const TSS = @import("gdt.zig").TSS;
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
};

const Process = struct {
    state: ProcessState,
    pid: u64,
    pml4: usize,
    kernel_stack: [*]u8,
    trap_frame: *TrapFrame,
    context: *Context,
};

const CPU = struct {
    gdt: [7]u64 = .{ 0, 0, 0, 0, 0, 0, 0 },
    tss: TSS = .{},
    scheduler_context: *Context = undefined,
    process: ?*Process = null,
};

var NEXT_PID: u64 = 0;
var LOCK = Spinlock{};
var PROCESSES: [MAX_NUM_PROCESSES]Process = [1]Process{Process{
    .state = .unused,
    .pid = undefined,
    .pml4 = undefined,
    .kernel_stack = undefined,
    .trap_frame = undefined,
    .context = undefined,
}} ** MAX_NUM_PROCESSES;
pub var CPU_STATE = CPU{};

extern fn handle_trap_ret() void;

pub fn allocProcess() ?*Process {
    LOCK.acquire();
    defer LOCK.release();

    var p: ?*Process = null;
    for (&PROCESSES) |*it| {
        if (it.state == .unused) {
            p = it;
        }
    }

    const proc: *Process = p orelse return null;
    proc.state = .embryo;
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
            switchContext(&CPU_STATE.scheduler_context, proc.context);
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
