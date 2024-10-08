//! Driver for I/O port based serial ports.

const std = @import("std");

const x86 = @import("x86.zig");
const outb = x86.outb;
const inb = x86.inb;
const ioapic = @import("interrupts/ioapic.zig");
const irq = @import("interrupts/irq.zig");

/// Base clock frequency
const BASE_FREQ: u32 = 115200;

/// First serial port base port
const UART1_BASE: u16 = 0x3F8;

/// Receive/transmit register offset, RW
const RX_TX: u16 = 0;
/// Interrupt enable register offset, RW
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

/// Represents a serial port.
const Uart = struct {
    initialized: bool = false,
    base_port: u16,

    const Self = @This();
    pub const Error = error{SelfTestFailed};

    /// Initialize the serial port with the following parameters:
    /// - clock frequency of 38400 Hz
    /// - 8 data bits, 1 stop bit, 0 parity bits
    /// - FIFO with 1 byte threshold
    /// - interrupts disabled
    pub fn init(self: *Self) Error!void {
        // Disable all interrupts
        outb(self.base_port + INT_EN, 0);

        // Set clock divisor to achieve frequency of 38400 Hz
        const div: u16 = @intCast(BASE_FREQ / 38400);
        const div_lo = div & 0xFF;
        const div_hi = (div >> 8) & 0xFF;
        outb(self.base_port + LINE_CTRL, 1 << 7);
        outb(self.base_port + RX_TX, div_lo);
        outb(self.base_port + INT_EN, div_hi);
        outb(self.base_port + LINE_CTRL, 0);

        // Set 8 data bits, 1 stop bit, 0 parity bits
        outb(self.base_port + LINE_CTRL, 0x2);

        // Enable FIFO, clear them, with 1-byte interrupt threshold
        outb(self.base_port + FIFO, 0x3);

        // Set RTS/DSR and enable loopback for testing
        outb(self.base_port + MODEM_CTRL, 0x12);

        // Write arbitrary byte for testing
        outb(self.base_port + RX_TX, '!');

        // Try to read same byte back
        // let b = self.rx_port.read();
        const c = inb(self.base_port + RX_TX);
        if (c != '!') {
            return Error.SelfTestFailed;
        }

        // Set RTS/DSR and disable loopback
        outb(self.base_port + MODEM_CTRL, 0xF);
    }

    /// Write a single byte to the serial port
    pub fn putc(self: *const Self, c: u8) void {
        var i: u8 = 0;
        while (i < 128) : (i += 1) {
            x86.pause();
            if (inb(self.base_port + LINE_STATUS) & 0x20 != 0) {
                break;
            }
        }
        outb(self.base_port + RX_TX, c);
    }

    /// Write many bytes to the serial port
    pub fn puts(self: *const Self, s: []const u8) void {
        for (s) |c| {
            self.putc(c);
        }
    }

    /// Alias for `puts`, used by `std.fmt.print`
    pub fn writeAll(self: *const Self, bytes: []const u8) Error!void {
        self.puts(bytes);
    }

    /// Used by `std.fmt.print`
    pub fn writeBytesNTimes(self: *const Self, bytes: []const u8, n: usize) Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.puts(bytes);
        }
    }

    /// Try to read a single byte from the serial port.
    /// Returns null if no data available.
    pub fn getc(self: *const Self) ?u8 {
        if (inb(self.base_port + LINE_STATUS) & 0x01 == 0)
            return null;
        return inb(self.base_port + RX_TX);
    }

    pub fn handleInterrupt(self: *const Self) void {
        _ = self.getc();
    }

    /// Enable UART1 interrupt in IOAPIC
    pub fn enableInterrupts(self: *const Self) void {
        outb(self.base_port + INT_EN, 1);
        ioapic.enable(irq.UART1, 0);
    }
};

/// Represents COM1
pub var UART1 = Uart{
    .base_port = UART1_BASE,
};

pub fn init() !void {
    try UART1.init();
}

/// Print formatted text to UART1
pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(UART1, fmt, args) catch {
        x86.spin();
    };
}
