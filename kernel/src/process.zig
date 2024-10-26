//! Module for managing user processes.

const std = @import("std");
const TrapFrame = @import("interrupts/idt.zig").TrapFrame;
const Spinlock = @import("Spinlock.zig");
const mem = @import("mem.zig");
const gdt = @import("gdt.zig");
const vfs = @import("vfs.zig");
const x86 = @import("x86.zig");
const MAX_PATH_LEN = @import("vfs/path.zig").MAX_PATH_LEN;
const panic = @import("panic.zig").panic;

/// Virtual address of bottom of user stack.
/// User-space stacks are currently limited to 1 page.
pub const USER_STACK_BOTTOM = 0x0000_6000_0000_0000;

pub const KERNEL_STACK_PAGE_COUNT = 4;
pub const KERNEL_STACK_BOTTOM = 0x0000_6100_0000_0000;
pub const KERNEL_STACK_TOP = KERNEL_STACK_BOTTOM + (KERNEL_STACK_PAGE_COUNT) * mem.PAGE_SIZE;

/// Maximum number of processes that can be allocated at the same time.
const MAX_NUM_PROCESSES = 16;

/// Important CPU state that needs to be saved for context switches.
/// The context switch is implemented as a function call to `switchContext`
/// (defined in switch_context.s)
/// The SysV ABI automatically pushes most CPU registers to the stack, but these registers
/// are not saved by default.
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

/// Process state and metadata.
const Process = struct {
    /// Name of the progress for debugging purposes
    name: []const u8,
    state: ProcessState,
    /// Unique id number
    pid: u64,
    /// Process from which this process was forked
    parent: ?*Process,
    /// Physical address of top-level paging table
    pml4: usize,
    /// Trap frame which resides in kernel stack
    trap_frame: *TrapFrame,
    /// Saved necessary CPU state which resides in kernel stack (for context switching)
    context: *Context,
    /// Status code passed to exit syscall
    exit_status: u64,
    /// Open files. File descriptors index into this array
    /// TODO: Extract the length into a variable
    files: [16]?vfs.File,
    /// When a process goes to sleep it sets this value to an arbitrary but sensible
    /// value before setting their state to `.sleeping`.
    /// Processes can be woken up by scanning the process table for processes with a matching
    /// `wait_channel` and setting their state to `.runnable`.
    /// The values used are typically the addresses of data structures the process tried to access
    /// or similar.
    wait_channel: u64,
    /// Current working directory. Relative paths are relative to this directory.
    cwd: [MAX_PATH_LEN:0]u8,

    pub fn getCWD(self: *const @This()) []const u8 {
        const cwd_len = std.mem.indexOfScalar(u8, &self.cwd, 0) orelse MAX_PATH_LEN;
        return self.cwd[0..cwd_len];
    }
};

/// General CPU state.
const CPU = struct {
    /// GDT used by the CPU when a process is being executed.
    gdt: [7]u64 = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// TSS used by the CPU when a process is being executed.
    tss: gdt.TSS = .{},
    /// CPU context for the scheduler. Whenever a context gets preempted or yields
    /// `contextSwitch` will be used to switch to this.
    scheduler_context: *Context = undefined,
    /// Currently active process for this CPU.
    process: ?*Process = null,
};

/// Strict monotonic rising counter for process ids.
var NEXT_PID: u64 = 0;
/// Lock for the process table, should be acquired before changing any process.
var LOCK = Spinlock{};
/// Process table.
pub var PROCESSES: [MAX_NUM_PROCESSES]Process = [1]Process{Process{
    .state = .unused,
    .name = undefined,
    .pid = undefined,
    .parent = undefined,
    .pml4 = undefined,
    .trap_frame = undefined,
    .context = undefined,
    .exit_status = undefined,
    .files = undefined,
    .wait_channel = undefined,
    .cwd = undefined,
}} ** MAX_NUM_PROCESSES;
/// CPU state.
pub var CPU_STATE = CPU{};

/// Defined in `interrupts/handle_trap.s`. Used to jump into userspace for the first time
/// by pretending we're returning from a fork syscall.
extern fn handleTrapRet() void;

/// Allocate a new proccess with the given name.
/// Returns an error if no process can be allocated.
/// Otherwise returns a pointer to the new process in the process table.
///
/// - Sets the state to `.embryo`
/// - Assigns a PID
/// - Allocates a kernel stack
/// - Sets trapframe & context to such that it's acting like returning from a fork syscall
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

    const proc_pml4 = mem.createPML4();
    proc.pml4 = mem.v2p(proc_pml4);
    var proc_mapper = mem.Mapper.forPML4(proc_pml4);
    var kernel_stack_top_page: u64 = undefined;
    for (0..KERNEL_STACK_PAGE_COUNT) |i| {
        const virt = mem.PAGE_ALLOCATOR.alloc();
        if (i == 0) kernel_stack_top_page = @intFromPtr(virt);
        const phys = mem.v2p(virt);
        proc_mapper.map(KERNEL_STACK_TOP - (1 + i) * mem.PAGE_SIZE, phys, .kernel, .panic);
    }

    var sp: usize = kernel_stack_top_page + mem.PAGE_SIZE;

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

/// Defined in switch_context.s
/// Switches CPU context to `new` and stores current CPU context in `old`.
extern fn switchContext(old: **Context, new: *Context) callconv(.SysV) void;

/// The scheduler activates interrupts and enters an infinite loop.
/// Traverses the process table to find a runnable process and runs it until it yields
/// or gets preempted, then moves onto the next process.
///
/// Basic round-robin scheduler.
pub fn scheduler() noreturn {
    while (true) {
        x86.sti();

        LOCK.acquire();
        for (&PROCESSES) |*proc| {
            if (proc.state != ProcessState.runnable) {
                continue;
            }

            proc.state = ProcessState.running;
            CPU_STATE.process = proc;
            CPU_STATE.tss.rsp0 = KERNEL_STACK_TOP;
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

/// Stop running the current process and switch back to scheduler.
/// Does not exit process.
pub fn yield() void {
    var proc = CPU_STATE.process orelse {
        panic("yield was called without an active process", .{});
    };

    LOCK.acquire();
    proc.state = ProcessState.runnable;
    switchContext(&proc.context, CPU_STATE.scheduler_context);
    LOCK.release();
}

/// Creates an exact copy of the active process and sets it as `.runnable`.
/// Copies all the user memory and page tables so that the processes are independent.
/// This is the main logic for the fork syscall.
pub fn doFork() !u64 {
    const this_proc = CPU_STATE.process orelse {
        panic("doFork was called without an active process", .{});
    };

    var new_proc = try allocProcess(this_proc.name);

    const this_pml4: *mem.PageTable = @alignCast(@ptrCast(mem.p2v(this_proc.pml4)));
    const new_pml4: *mem.PageTable = @alignCast(@ptrCast(mem.p2v(new_proc.pml4)));

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

                    if (virt >= KERNEL_STACK_BOTTOM) continue;

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
    new_proc.cwd = this_proc.cwd;
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

/// Mimics the return path of the fork syscall.
/// Used for the initial launch into userspace.
fn forkRet() void {
    LOCK.release();
}

/// Exits the current process and set its exit code.
/// The memory for a process isn't immediately reclaimed, instead it enters a `.zombie` state.
/// This way the parent process can reap it later and read its exit code.
/// This is the main logic for the exit syscall.
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
    @import("logger.zig").log(.debug, "process", "process {s} exited with status code {}", .{ proc.name, proc.exit_status });
    switchContext(&proc.context, CPU_STATE.scheduler_context);
    panic("switchContext returned to doExit", .{});
}

/// Allocate a new file descriptor for the current process and associate it with
/// the given file handle.
pub fn addOpenFile(proc: *Process, file: vfs.File) !u64 {
    for (&proc.files, 0..) |*open_file, i| {
        if (open_file.* == null) {
            open_file.* = file;
            return i;
        }
    }
    return error.TooManyOpenFiles;
}

/// Sleep on a `wait_channel`, waiting for the corresponding `awaken` call.
/// The given `lock` will be released inside this function. Once the process is woken back up
/// the function will return with `lock` already acquired.
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

/// Acquire the process table lock and awaken all processes wait the given `wait_channel`,
/// setting their states to `.runnable`.
pub fn awaken(wait_channel: u64) void {
    LOCK.acquire();
    defer LOCK.release();

    awakenWithLock(wait_channel);
}

/// Awaken all processes wait the given `wait_channel`, setting their states to `.runnable`.
/// Requires the process table lock to be acquired already.
pub fn awakenWithLock(wait_channel: u64) void {
    for (&PROCESSES) |*proc| {
        if (proc.state == ProcessState.sleeping and proc.wait_channel == wait_channel) {
            proc.state = ProcessState.runnable;
        }
    }
}

/// Causes the current process to wait for a child process to exit.
/// If no child processes exist this will return immediately.
/// If child processes exist but none have exited the process will go to sleep.
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

            // TODO: free p's memory
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

/// Load a new program image and replace the current one.
/// This is the main logic for the exec syscall.
pub fn doExec(path: []const u8) !void {
    const proc = CPU_STATE.process orelse {
        panic("exec was called without an active process", .{});
    };

    const elf = std.elf;

    const file = vfs.open(path) orelse return error.NoSuchFile;
    const limine_file = switch (file) {
        .limine => |f| f.ref,
        .tty => return error.NoSuchFile,
        .fat16 => return error.NoSuchFile,
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
