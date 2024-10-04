//! 8042 PS/2 controller driver.
//!
//! The controller can support one or two ports, i.e. one or two devices.
//! As far as I understand the first port is typically connected to a keyboard
//! while the second port is used for a mouse (if present).
//!
//! The `init` function will detect the available ports and what type of device are connected.
//! When initialized the most important functions are `writePort1`, `writePort2`, `readData`
//! and `tryReadData`.
//! When the PS/2 devices send data to the CPU they share a common buffer. So when reading
//! there is no simple way to tell which device a piece of data came from. The device drivers
//! will have to manage that manually (i.e. by never talking to both devices at the same time).
//!
//! Since a device could not be available or become unavailable during operation
//! the functions to communicate with them will fail after a certain amount of retries
//! (see `NUM_ATTEMPTS`).
//!
//! See also: https://wiki.osdev.org/%228042%22_PS/2_Controller

const x86 = @import("x86.zig");

/// Number of attempts to use when reading data before timing out
const NUM_ATTEMPTS = 100;

const Port = struct {
    /// Port number for data register (R/W)
    const data = 0x60;
    /// Port number for status register (R)
    /// and for command register (W)
    const status_cmd = 0x64;
};

const Command = enum(u8) {
    /// Read configuration byte
    read_config_byte = 0x20,
    /// Write configuration byte
    write_config_byte = 0x60,
    /// Self-test controller
    test_controller = 0xaa,
    /// Test port 1
    test_port1 = 0xab,
    /// Test port 2
    test_port2 = 0xa9,
    /// Enable port 1
    enable_port1 = 0xae,
    /// Enable port 2
    enable_port2 = 0xa8,
    /// Disable port 1
    disable_port1 = 0xad,
    /// Disable port 2
    disable_port2 = 0xa7,
    /// Tells the controller to send the next data byte to port 2
    write_port2 = 0xd4,
};

/// Represents 8042 status register
const Status = packed struct {
    /// 0: Output buffer is for data sent from the controller to the CPU
    output_buffer_filled: bool,
    /// 1: Input buffer is for data sent from the controller to the CPU
    input_buffer_filled: bool,
    /// 2: Cleared on reset and set by firmware if self-test passes
    self_test_passed: bool,
    /// 3: If cleared data written to input buffer is sent to PS/2 device,
    /// otherwise data is sent to controller
    command_data: bool,
    /// 4:
    reserved1: bool,
    /// 5:
    reserved2: bool,
    /// 6: Set if error
    timeout_error: bool,
    /// 7: Set if error
    parity_error: bool,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("Status has wrong size");
    }
};

/// Represents the configuration byte ("byte 0" of controller RAM)
const ConfigByte = packed struct {
    /// 0:
    port1_interrupt_enabled: bool,
    /// 1:
    port2_interrupt_enabled: bool,
    /// 2: System passed self-test
    self_test_passed: bool,
    /// 3: Always 0
    zero1: bool,
    /// 4:
    port1_clock_disabled: bool,
    /// 5:
    port2_clock_disabled: bool,
    /// 6: If set scancodes from keyboard connected to port 1 are translated
    port1_translation_enabled: bool,
    /// 7: Always 0
    zero2: bool,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("ConfigByte has wrong size");
    }
};

const PortStatus = enum {
    /// Port has not been tested for or initialized in any way
    uninitialized,
    /// Port does not exist on the controller
    absent,
    /// Ports existence has been established
    exists,
    /// Port has failed self-test
    failed_test,
    /// Port passed self-test but no device could be detected
    no_device,
    /// Port passed self-test and a device has been detected and reset
    initialized,
};

const DeviceType = enum {
    keyboard,
    mouse,
    mouse_with_wheel,
    _5_button_mouse,
    mf2_keyboard,
    short_keyboard,
    ncd_n97_keyboard,
    _122_key_keyboard,
    jp_g_keyboard,
    jp_p_keyboard,
    jp_a_keyboard,
    ncd_sun_keyboard,
};

var port1_status: PortStatus = .exists;
var port1_device: ?DeviceType = null;
var port2_status: PortStatus = .uninitialized;
var port2_device: ?DeviceType = null;

/// Send a command to the controller
fn command0(cmd: Command) void {
    x86.outb(Port.status_cmd, @intFromEnum(cmd));
}

/// Send a command along with additional data to the controller
fn command1(cmd: Command, data: u8) void {
    x86.outb(Port.status_cmd, @intFromEnum(cmd));
    x86.outb(Port.data, data);
}

/// Read status register
fn status() Status {
    const bits = x86.inb(Port.status_cmd);
    return @bitCast(bits);
}

/// Read from data register.
/// Data must be available (check `Status.output_buffer_filled`)
pub fn readData() u8 {
    return x86.inb(Port.data);
}

/// Try to read from data register.
/// Waits a certain amount of time for data to be available before returning with an error.
pub fn tryReadData() !u8 {
    var i: u64 = NUM_ATTEMPTS;
    while (!status().output_buffer_filled) : (i -= 1) {
        if (i == 0) return error.Timeout;
    }
    return readData();
}

/// Write to data register.
/// Input buffer must not be full (check `Status.input_buffer_filled`)
fn writeData(b: u8) void {
    return x86.outb(Port.data, b);
}

/// Read config byte
fn readConfig() ConfigByte {
    command0(.read_config_byte);
    return @bitCast(readData());
}

/// Write config byte
fn writeConfig(config: ConfigByte) void {
    command1(.write_config_byte, @bitCast(config));
}

/// Write a byte to the device on port 1
pub fn writePort1(b: u8) !void {
    var i: u8 = NUM_ATTEMPTS;
    while (status().input_buffer_filled) : (i -= 1) {
        if (i == 0) return error.Timeout;
    }
    writeData(b);
}

/// Write a byte to the device on port 2
pub fn writePort2(b: u8) !void {
    var i: u8 = NUM_ATTEMPTS;
    while (status().input_buffer_filled) : (i -= 1) {
        if (i == 0) return error.Timeout;
    }
    command0(.write_port2);
    writeData(b);
}

/// Try to detect and initialize the two ports of the controller.
/// By the end both devices will be enabled (if possible) and interrupts will be enabled.
/// Translation for port 1 will be disabled.
pub fn init() !void {
    // Disable port so they don't do anything during initialization
    // that could mess things up
    command0(.disable_port1);
    command0(.disable_port2);

    // Flush output buffer
    while (status().output_buffer_filled) {
        _ = readData();
    }

    var config = readConfig();
    config.port1_interrupt_enabled = false;
    config.port1_clock_disabled = false;
    config.port1_translation_enabled = false;
    writeConfig(config);

    // Perform self-test
    command0(.test_controller);
    while (!status().output_buffer_filled) {}
    if (readData() != 0x55) {
        return error.SelfTestFailed;
    }

    // Write config again because self-test can reset the controller
    writeConfig(config);

    // Check if port 2 exists on the controller
    command0(.enable_port2);
    port2_status = if (!readConfig().port2_clock_disabled) .exists else .absent;
    if (port2_status == .exists) {
        // If it exists disable it again for now
        command0(.disable_port2);
    }

    // While checking for port 2 the config might have gotten reset.
    config = readConfig();
    config.port1_interrupt_enabled = true;
    config.port1_clock_disabled = false;
    config.port1_translation_enabled = false;
    config.port2_interrupt_enabled = false;
    config.port2_clock_disabled = false;
    writeConfig(config);

    // Perform self-tests on each port
    command0(.test_port1);
    if (readData() != 0) {
        port1_status = .failed_test;
    }
    if (port2_status == .exists) {
        command0(.test_port2);
        if (readData() != 0) {
            port2_status = .failed_test;
        }
    }

    // Check if any ports are present and passed the tests
    if (port1_status == .failed_test and port2_status == .failed_test) {
        return error.NoPorts;
    }

    // Enable the available ports and reset the devices
    if (port1_status == .exists) {
        command0(.enable_port1);

        // PS/2 device reset command
        try writePort1(0xff);
        if (handleResetResponse()) |device| {
            port1_status = .initialized;
            port1_device = device;
        } else |e| {
            @import("uart.zig").print("failed to initialized device on port 1: {}\n", .{e});
            port1_status = .no_device;
        }
    }
    if (port2_status == .exists) {
        command0(.enable_port2);

        // PS/2 device reset command
        try writePort2(0xff);
        if (handleResetResponse()) |device| {
            port2_status = .initialized;
            port2_device = device;
        } else |e| {
            @import("uart.zig").print("failed to initialized device on port 2: {}\n", .{e});
            port2_status = .no_device;
        }
    }
    // TODO: also enable IRQs here in the future

    @import("uart.zig").print("port 1: {}, {?}\nport 2: {}, {?}\n", .{
        port1_status,
        port1_device,
        port2_status,
        port2_device,
    });
}

/// After sending the reset command (0xff) to a port call this function to handle the response.
///
/// After receiving the reset command a device will respond with up to 4 bytes of data.
/// The first two are the result of a self-test, which should be `fa aa` or `aa fa` (apparently both
/// are allowed according to the osdev wiki). After that it sends an identification code for the
/// type of device it represents.
fn handleResetResponse() !DeviceType {
    const resp1 = tryReadData() catch return error.NoResponse1;
    const resp2 = tryReadData() catch return error.NoResponse2;

    // Apparently the reset response can come in different orders
    if ((resp1 != 0xfa or resp2 != 0xaa) and (resp1 != 0xaa or resp2 != 0xfa)) {
        return error.InvalidResponse;
    }

    const resp3 = tryReadData() catch return .keyboard;
    return switch (resp3) {
        0x00 => .mouse,
        0x03 => .mouse_with_wheel,
        0x04 => ._5_button_mouse,
        0xab => {
            const resp4 = tryReadData() catch return error.NoResponse4;
            return switch (resp4) {
                0x83 | 0xc1 => .mf2_keyboard,
                0x84 => .short_keyboard,
                0x85 => .ncd_n97_keyboard,
                0x86 => ._122_key_keyboard,
                0x90 => .jp_g_keyboard,
                0x91 => .jp_p_keyboard,
                0x92 => .jp_a_keyboard,
                0xa1 => .ncd_sun_keyboard,
                else => error.UnrecognizedDevice,
            };
        },
        else => error.UnrecognizedDevice,
    };
}
