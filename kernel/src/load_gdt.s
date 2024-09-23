.section .text
.global loadGDT
loadGDT:
        lgdt (%rdi)
        movw %dx, %ds
        movw %dx, %es
        movw %dx, %fs
        movw %dx, %gs
        movw %dx, %ss

        push %rsi
        lea 1f(%rip), %rdi
        push %rdi
        lretq
1:
        ret
