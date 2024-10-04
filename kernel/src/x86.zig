//! Collections of little helper/wrapper functions for accessing
//! special CPU instructions and registers that you normally don't have access to.

/// Write a byte of data to the given I/O port.
pub fn outb(port: u16, data: u8) void {
    asm volatile ("outb %al, %dx"
        :
        : [port] "{dx}" (port),
          [data] "{al}" (data),
    );
}

/// Write a byte of data to the given I/O port.
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %dx, %al"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Spin loop hint. Allows the CPU to execute busy-loops more efficiently.
/// Example:
/// ```
/// while (!data_available) {
///     pause();
/// }
/// ```
pub fn pause() void {
    asm volatile ("pause");
}

/// Sends the CPU into a never-ending HALT loop, i.e. CPU will stop execution
/// save for interrupts (if enabled).
pub fn spin() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Read the CR2 register.
/// The CR2 register stores the offending memory address during a page fault.
pub fn readCR2() u64 {
    return asm volatile ("mov %cr2, %rax"
        : [cr2] "={rax}" (-> u64),
    );
}

/// Read the CR3 register.
/// The CR3 register contains the physical address of the currently active top-level
/// page table as well as a few paging related flags.
pub fn readCR3() struct { page_table: u64, flags: u64 } {
    const cr3: u64 =
        asm volatile ("mov %cr3, %rax"
        : [cr3] "={rax}" (-> u64),
    );

    return .{
        .page_table = cr3 & 0o777_777_777_777_0000,
        .flags = cr3 & 0o7777,
    };
}

/// Write to the CR3 register.
pub fn writeCR3(
    /// Physical address of the top-level page table to use
    page_table: u64,
    flags: u64,
) void {
    const cr3 = page_table | flags;
    asm volatile ("mov %rax, %cr3"
        :
        : [rax] "{rax}" (cr3),
    );
}
