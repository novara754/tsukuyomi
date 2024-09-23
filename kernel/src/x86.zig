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
