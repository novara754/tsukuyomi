pub fn outb(port: u16, data: u8) void {
    asm volatile ("outb %al, %dx"
        :
        : [port] "{dx}" (port),
          [data] "{al}" (data),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %dx, %al"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn pause() void {
    asm volatile ("pause");
}

pub fn spin() noreturn {
    while (true) {
        asm volatile ("pause");
    }
}

pub fn readCR2() u64 {
    return asm volatile ("mov %cr2, %rax"
        : [cr2] "={rax}" (-> u64),
    );
}

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

pub fn writeCR3(page_table: u64, flags: u64) void {
    const cr3 = page_table | flags;
    asm volatile ("mov %rax, %cr3"
        :
        : [rax] "{rax}" (cr3),
    );
}
