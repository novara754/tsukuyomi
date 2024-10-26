pub const STDIN_FILENO = 0;
pub const STDOUT_FILENO = 1;
pub const STDERR_FILENO = 2;

pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;

const SYS_READ = 0;
const SYS_WRITE = 1;
const SYS_OPEN = 2;
const SYS_CLOSE = 3;
const SYS_GETDIRENTS = 4;
const SYS_SETCWD = 56;
const SYS_FORK = 57;
const SYS_EXECVE = 59;
const SYS_EXIT = 60;
const SYS_WAIT = 61;

pub const pid_t = c_int;

fn syscall0(nr: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
        : "rcx", "r11"
    );
}

fn syscall1(nr: u64, rdi: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [rdi] "{rdi}" (rdi),
        : "rcx", "r11"
    );
}

fn syscall2(nr: u64, rdi: u64, rsi: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [rdi] "{rdi}" (rdi),
          [rsi] "{rsi}" (rsi),
        : "rcx", "r11"
    );
}

fn syscall3(nr: u64, rdi: u64, rsi: u64, rdx: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [rdi] "{rdi}" (rdi),
          [rsi] "{rsi}" (rsi),
          [rdx] "{rdx}" (rdx),
        : "rcx", "r11"
    );
}

fn syscall4(nr: u64, rdi: u64, rsi: u64, rdx: u64, r10: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [rdi] "{rdi}" (rdi),
          [rsi] "{rsi}" (rsi),
          [rdx] "{rdx}" (rdx),
          [r10] "{r10}" (r10),
        : "rcx", "r11"
    );
}

pub fn read(fd: c_int, buf: [*]u8, count: usize) isize {
    return @intCast(syscall3(SYS_READ, @intCast(fd), @intFromPtr(buf), @intCast(count)));
}

pub fn write(fd: c_int, buf: [*]const u8, count: usize) isize {
    return @intCast(syscall3(SYS_WRITE, @intCast(fd), @intFromPtr(buf), @intCast(count)));
}

pub fn open(filename: [*:0]const u8, flags: c_int) c_int {
    return @intCast(syscall2(SYS_OPEN, @intFromPtr(filename), @intCast(flags)));
}

pub fn close(fd: c_int) c_int {
    return @intCast(syscall1(SYS_CLOSE, @intCast(fd)));
}

pub fn getdirents(fd: c_int, buf: [*]DirEntry, count: usize) usize {
    return @intCast(syscall3(SYS_GETDIRENTS, @intCast(fd), @intFromPtr(buf), @intCast(count)));
}

pub fn wait() u64 {
    return @intCast(syscall0(SYS_WAIT));
}

pub fn setcwd(path: [*:0]const u8) c_int {
    return @intCast(syscall1(SYS_SETCWD, @intFromPtr(path)));
}

pub fn fork() pid_t {
    return @intCast(syscall0(SYS_FORK));
}

pub fn execve(pathname: [*:0]u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int {
    return @intCast(syscall3(SYS_EXECVE, @intFromPtr(pathname), @intFromPtr(argv), @intFromPtr(envp)));
}
pub fn _exit(status: c_int) noreturn {
    _ = syscall1(SYS_EXIT, @intCast(status));
    unreachable;
}

pub const DirEntry = extern struct {
    name: [256:0]u8,
};
