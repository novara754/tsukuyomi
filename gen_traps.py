TRAPS = [
    ("division_error", False),
    ("debug", False),
    ("nmi", False),
    ("breakpoint", False),
    ("overflow", False),
    ("bound_range_exceeded", False),
    ("invalid_opcode", False),
    ("device_not_available", False),
    ("double_fault", True),
    ("coprocessor_segment_overrun", False),
    ("invalid_tss", True),
    ("segment_not_present", True),
    ("stack_segment_fault", True),
    ("general_protection_fault", True),
    ("page_fault", True),
    ("reserved15", False),
    ("x87_fp_exception", False),
    ("alignment_check", True),
    ("machine_check", False),
    ("simd_fp_exception", False),
    ("virtualization_exception", False),
    ("control_protection_exception", True),
    ("reserved22", False),
    ("reserved23", False),
    ("reserved24", False),
    ("reserved25", False),
    ("reserved26", False),
    ("reserved27", False),
    ("hypervisor_injection", False),
    ("vmm_communication_exception", True),
    ("security_exception", True),
    ("reserved31", False),
]

def main():
    print(".section .text")
    print(".extern handleTrap")
    for (i, (name, has_err_code)) in enumerate(TRAPS):
        print(f".global {name}")
        print(f"{name}:")
        if not has_err_code:
            print("\tpushq $0")
        print(f"\tpushq ${i}")
        print("\tjmp handleTrap\n")

    for i in range(32, 256):
        print(f".global vector{i}")
        print(f"vector{i}:")
        print("\tpush $0")
        print(f"\tpush ${i}")
        print("\tjmp handleTrap\n")

    print(".section .data")
    print(".global trap_table")
    print("trap_table:")
    for (name, _) in TRAPS:
        print(f"\t.quad {name}")
    for i in range(32, 256):
        print(f"\t.quad vector{i}")


if __name__ == "__main__":
    main()
