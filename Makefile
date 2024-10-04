KERNEL = kernel/zig-out/bin/tsukuyomi
USER_PROGS = user/zig-out/bin

NUM_CPUS ?= 1

QEMU = qemu-system-x86_64
QEMU_ARGS = \
    -smp $(NUM_CPUS) \
    -drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
    -drive if=pflash,format=raw,readonly=on,file=$(OVMF_VARS) \
    -drive format=raw,file=hdd.img \
    -no-reboot \
    -serial stdio

QEMU_EXTRA ?=

ifdef RELEASE
ZIG_RELEASE = -Drelease=true
endif

.PHONY: all
all: kernel

.PHONY: install
install: $(KERNEL) hdd.img
	sudo losetup /dev/loop0 hdd.img --offset 1048576 --sizelimit 16777216
	sudo mount /dev/loop0 hdd_esp
	sudo cp $(KERNEL) hdd_esp/boot/
	sudo mkdir -p hdd_esp/usr/
	sudo cp $(USER_PROGS)/* hdd_esp/usr/
	sudo umount hdd_esp
	sudo losetup --detach /dev/loop0

.PHONY: docs
docs:
	cd kernel && zig build-lib -femit-docs=../docs -fno-emit-bin src/lib.zig

.PHONY: kernel-test
kernel-test:
	cd kernel && zig build test -Dtarget=native

.PHONY: kernel
kernel: $(KERNEL)

.PHONY: $(KERNEL)
$(KERNEL): user kernel/src/interrupts/traps.s
	cd kernel && zig build $(ZIG_RELEASE)
	objdump -dS -M intel $(KERNEL) > $(KERNEL).asm

.PHONY: user
user:
	cd user && zig build

kernel/src/interrupts/traps.s: gen_traps.py
	python gen_traps.py >> $@

hdd.img: ./mkfs.sh limine.conf
	./mkfs.sh

.PHONY: qemu
qemu: install
	$(QEMU) $(QEMU_EXTRA) $(QEMU_ARGS)

.PHONY: qemu-gdb
qemu-gdb: install
	$(QEMU) $(QEMU_EXTRA) $(QEMU_ARGS) -S -s

.PHONY: clean
clean:
	rm -rf kernel/zig-out hdd.img
