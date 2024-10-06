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
const Terminal = @import("Terminal.zig");

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

// TODO: Would it be necessary to go back to `.waiting` after a certain timeout?
// TODO: The current state machine does not handle the more complicated scan codes such as
// `E1 14 77 E1 F0 14 F0 77` for the PAUSE key.
/// The interrupt handler gets invoked for every byte the keyboards sends to the CPU,
/// so a simple state machine is used to handle the different scan code sequences.
pub fn handleInterrupt() void {
    const state = struct {
        var state: State = .waiting;
    };

    const data = ps2.tryReadData() catch {
        uart.print("got kbd interrupt but no data\n", .{});
        return;
    };
    switch (state.state) {
        .waiting => {
            if (data == 0xf0) {
                state.state = .got_f0;
            } else if (data == 0xe0) {
                state.state = .got_e0;
            } else {
                if (getKeyCode(data, false)) |key| {
                    handleEvent(.{ .key = key, .action = .down });
                }
                state.state = .waiting;
            }
        },
        .got_e0 => {
            if (data == 0xf0) {
                state.state = .got_e0_f0;
            } else {
                if (getKeyCode(data, true)) |key| {
                    handleEvent(.{ .key = key, .action = .down });
                }
                state.state = .waiting;
            }
        },
        .got_f0 => {
            if (getKeyCode(data, false)) |key| {
                handleEvent(.{ .key = key, .action = .up });
            }
            state.state = .waiting;
        },
        .got_e0_f0 => {
            if (getKeyCode(data, true)) |key| {
                handleEvent(.{ .key = key, .action = .up });
            }
            state.state = .waiting;
        },
    }
}

// TODO: In the future keycodes should be more abstract and not directly
// tied to a specific key for a specific layout. Instead it should probably
// just be some arbitrary number that can then be mapped to a specific key through
// a keyboard layout mapping that can be loaded at runtime.
// The keycode should then just represent the key's position on the keyboard in some way.
/// Key codes are a more ordered way to enumerate the keys on a keyboard. The scan codes reported
/// by the keyboard are all over the place and don't lend themselves well to translating them into
/// ASCII characters etc.
const KeyCode = enum(u8) {
    a = 'a',
    b = 'b',
    c = 'c',
    d = 'd',
    e = 'e',
    f = 'f',
    g = 'g',
    h = 'h',
    i = 'i',
    j = 'j',
    k = 'k',
    l = 'l',
    m = 'm',
    n = 'n',
    o = 'o',
    p = 'p',
    q = 'q',
    r = 'r',
    s = 's',
    t = 't',
    u = 'u',
    v = 'v',
    w = 'w',
    x = 'x',
    y = 'y',
    z = 'z',
    enter = '\n',
    space = ' ',
    shift,
};

const KeyAction = enum {
    /// Key was just pushed down or is being held down and keyboard sent repeat event
    down,
    /// Key was just released
    up,
};

/// After the interrupt handler reads out the scan codes from the keyboard
/// they are turned into a key event which can then be used by the rest of the system.
const KeyEvent = struct {
    key: KeyCode,
    action: KeyAction,
};

/// Convert a scan code to a key code. See also `KeyCode`.
fn getKeyCode(scanCode: u8, extended: bool) ?KeyCode {
    if (extended) {
        return switch (scanCode) {
            else => null,
        };
    } else {
        return switch (scanCode) {
            0x1c => .a,
            0x32 => .b,
            0x21 => .c,
            0x23 => .d,
            0x24 => .e,
            0x2b => .f,
            0x34 => .g,
            0x33 => .h,
            0x43 => .i,
            0x3b => .j,
            0x42 => .k,
            0x4b => .l,
            0x3a => .m,
            0x31 => .n,
            0x44 => .o,
            0x4d => .p,
            0x15 => .q,
            0x2d => .r,
            0x1b => .s,
            0x2c => .t,
            0x3c => .u,
            0x2a => .v,
            0x1d => .w,
            0x22 => .x,
            0x35 => .y,
            0x1a => .z,
            0x12 => .shift,
            0x5a => .enter,
            0x29 => .space,
            else => null,
        };
    }
}

/// For now key events will simply tell the Terminal to print the appropriate characters.
fn handleEvent(event: KeyEvent) void {
    const state = struct {
        var shiftHeld: bool = false;
    };

    const term = &(Terminal.SINGLETON orelse return);

    if (event.key == .shift) {
        state.shiftHeld = event.action == .down;
    } else if (event.action == .down) {
        var c = @intFromEnum(event.key);
        if (state.shiftHeld) {
            c &= ~@as(u8, 0x20);
        }
        term.putc(c);
    }
}
