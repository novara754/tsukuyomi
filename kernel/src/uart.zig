const x86 = @import("x86.zig");
const outb = x86.outb;
const inb = x86.inb;

//// Base clock frequency
const BASE_FREQ: u32 = 115200;

//// First serial port base port
const COM1: u16 = 0x3F8;

//// Receive/transmit register offset, RW
const RX_TX: u16 = 0;
//// Interrupt enable register offset, RW
const INT_EN: u16 = 1;
// /// Interrupt ID register offset, RO
// const INT_ID: u16 = 2;
/// FIFO control register offset, WO
const FIFO: u16 = 2;
/// Line control register offset, RW
const LINE_CTRL: u16 = 3;
/// Modem control register offset, RW
const MODEM_CTRL: u16 = 4;
/// Line status register offset, RO
const LINE_STATUS: u16 = 5;

pub fn init() bool {
    // Disable all interrupts
    outb(COM1 + INT_EN, 0);

    // Set clock divisor to achieve frequency of 38400 Hz
    const div: u16 = @intCast(BASE_FREQ / 38400);
    const div_lo = div & 0xFF;
    const div_hi = (div >> 8) & 0xFF;
    outb(COM1 + LINE_CTRL, 1 << 7);
    outb(COM1 + RX_TX, div_lo);
    outb(COM1 + INT_EN, div_hi);
    outb(COM1 + LINE_CTRL, 0);

    // Set 8 data bits, 1 stop bit, 0 parity bits
    outb(COM1 + LINE_CTRL, 0x2);

    // Enable FIFO, clear them, with 1-byte interrupt threshold
    outb(COM1 + FIFO, 0x3);

    // Set RTS/DSR and enable loopback for testing
    outb(COM1 + MODEM_CTRL, 0x12);

    // // Write arbitrary byte for testing
    outb(COM1 + RX_TX, '!');

    // Try to read same byte back
    // let b = self.rx_port.read();
    const c = inb(COM1 + RX_TX);
    if (c != '!') {
        return false;
    }

    // Set RTS/DSR and disable loopback
    outb(COM1 + MODEM_CTRL, 0xF);

    return true;
}

pub fn putc(c: u8) void {
    var i: u8 = 0;
    while (i < 128) : (i += 1) {
        x86.pause();
        if (inb(COM1 + 5) & 0x20 != 0) {
            break;
        }
    }
    outb(COM1 + 0, c);
}

pub fn puts(s: []const u8) void {
    for (s) |c| {
        putc(c);
    }
}
