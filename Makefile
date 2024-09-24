KERNEL = kernel/zig-out/bin/tsukuyomi

NUM_CPUS ?= 1

QEMU = qemu-system-x86_64
QEMU_ARGS = \
    -smp $(NUM_CPUS) \
    -drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
    -drive if=pflash,format=raw,readonly=on,file=$(OVMF_VARS) \
    -drive format=raw,file=hdd.img \
    -no-reboot \
    -nographic \
    -serial mon:stdio
QEMU_EXTRA ?=

.PHONY: all
all: kernel

.PHONY: install-kernel
install-kernel: $(KERNEL) hdd.img
	sudo losetup /dev/loop0 hdd.img --offset 1048576 --sizelimit 16777216
	sudo mount /dev/loop0 hdd_esp
	sudo cp $(KERNEL) hdd_esp/boot/
	sudo umount hdd_esp
	sudo losetup --detach /dev/loop0

.PHONY: kernel
kernel: $(KERNEL)

.PHONY: $(KERNEL)
$(KERNEL): kernel/src/interrupts/traps.s
	cd kernel && zig build
	objdump -d -M intel $(KERNEL) > $(KERNEL).asm

kernel/src/interrupts/traps.s: gen_traps.py
	python gen_traps.py >> $@

hdd.img: ./mkfs.sh limine.conf
	./mkfs.sh

.PHONY: qemu
qemu: install-kernel
	$(QEMU) $(QEMU_EXTRA) $(QEMU_ARGS)

.PHONY: qemu-gdb
qemu-gdb: install-kernel
	$(QEMU) $(QEMU_EXTRA) $(QEMU_ARGS) -S -s

.PHONY: clean
clean:
	rm -rf kernel/zig-out hdd.img
