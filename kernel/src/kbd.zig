//! Driver for PS/2 keyboards connected to the first port of the PS/2 controller
//!
//! The PS/2 keyboard sends sequences of scan codes to the CPU when a key is pressed.
//! There are different sets of scan codes, i.e. different ways to encode the same keys
//! being pressed or released. By default scan code set 2 is enabled, which is the only one
//! this driver uses.
const ps2 = @import("ps2.zig");
const uart = @import("uart.zig");
const ioapic = @import("interrupts/ioapic.zig");
const irq = @import("interrupts/irq.zig");

const ECHO = 0xee;
const ACK = 0xfa;
const RESEND = 0xfe;

const Command = enum(u8) {
    /// Echo, keyboard will send 0xee back
    echo = ECHO,
    /// Start scanning for input from user
    start_scanning = 0xf4,
};

/// Send a command to the keyboard, retry up to 5 times if keyboard
/// sends RESEND response.
fn command(cmd: Command) !u8 {
    var resp: u8 = RESEND;
    var i: u8 = 5;
    while (resp == RESEND and i > 0) : (i -= 1) {
        try ps2.writePort1(@intFromEnum(cmd));
        resp = try ps2.tryReadData();
    }
    if (i == 0) return error.TooManyResends;
    return resp;
}

/// Like `command` but check for ACK response.
fn commandAndAck(cmd: Command) !void {
    if (try command(cmd) != ACK) {
        return error.NoAck;
    }
}

/// Initialize PS/2 keyboard by doing an ECHO test, enabling scanning
/// and then enabling interrupts
pub fn init() !void {
    // Try a basic echo test
    if (try command(.echo) != ECHO) return error.EchoFailed;
    try commandAndAck(.start_scanning);
    ioapic.enable(irq.KBD, 0);
}

/// State for the interrupt handler.
/// Possible sequences are:
/// - pressing a simple key: waiting => waiting
/// - releasing a simple key: waiting => got_f0 => waiting
/// - pressing an extended key: waiting => got_e0 => waiting
/// - releasing an extended key: waiting => got_e0 => got_f0 => waiting
const State = enum {
    /// Waiting for the start of a new scancode sequence
    waiting,
    /// Received 0xe0, now waiting for which extended key was pressed or 0xf0
    got_e0,
    /// Received 0xf0, now waiting for which key was released
    got_f0,
    /// Received 0xf0 after 0xe0, now waiting for which extended key was released
    got_e0_f0,
};

var state: State = .waiting;

// TODO: Would it be necessary to go back to `.waiting` after a certain timeout?
/// The interrupt handler gets invoked for every byte the keyboards sends to the CPU,
/// so a simple state machine is used to handle the different scan code sequences.
pub fn handleInterrupt() void {
    const data = ps2.tryReadData() catch {
        uart.print("got kbd interrupt but no data\n", .{});
        return;
    };
    switch (state) {
        .waiting => {
            if (data == 0xf0) {
                state = .got_f0;
            } else if (data == 0xe0) {
                state = .got_e0;
            } else {
                uart.print("kbd: {x}\n", .{data});
                state = .waiting;
            }
        },
        .got_e0 => {
            if (data == 0xf0) {
                state = .got_e0_f0;
            } else {
                uart.print("kbd: e0 {x}\n", .{data});
                state = .waiting;
            }
        },
        .got_f0 => {
            uart.print("kbd: f0 {x}\n", .{data});
            state = .waiting;
        },
        .got_e0_f0 => {
            uart.print("kbd: e0 f0 {x}\n", .{data});
            state = .waiting;
        },
    }
}
