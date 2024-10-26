# Tsukuyomi

> [!IMPORTANT]
> This project is still under heavy development and incomplete.

Tsukuyomi is a hobby operating system from scratch made purely for educational purposes.
Currently it only supports 64-bit [x86] platforms.

![screenshot of os running in qemu, the `hello` and `ls` programs are being run in the shell](screenshot.png)

The kernel is a [monolithic kernel] designed to work with the [Limine boot protocol]

The following things are implemented so far:
- Output and input over serial port
- Output via text written to framebuffer using PC Screen Fonts
- Basic input through PS/2 keyboard
- Physical page allocator
- Interrupts and syscall handlers
- ATA PIO driver
- Parts of a FAT16 filesystem driver
- Virtual File System to allow for [device-as-files] philosophy
- User-mode processes
- Logging framework

Supported syscalls:
- `open(path)`: open a file
- `read(fd, buf, count)`: read from a file
- `write(fd, buf, count)`: write to a file
- `close(fd)`: close a file
- `getdirents(fd, buf, count)`: read directory entries
- `wait`: wait on a child process to exit
- `setcwd(path)`: set current working directory
- `fork()`: create a duplicate of the process as child
- `execve(path, argv, envp)`: set process image
- `exit(status)`: exit process with status code

There are three basic programs available to run in user-mode:
- `sh`: a shell, started by default by the kernel
- `ls`: list entries of current working directory
- `hello`: print "hello world" to the screen

[x86]: https://en.wikipedia.org/wiki/X86
[monolithic kernel]: https://en.wikipedia.org/wiki/Monolithic_kernel
[Limine boot protocol]: https://limine-bootloader.org/
[device-as-files]: https://en.wikipedia.org/wiki/Device_file
