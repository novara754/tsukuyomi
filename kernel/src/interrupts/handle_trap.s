.section .text
.extern handle_trap_inner
.global handle_trap
.global handle_trap_ret
handle_trap:
	pushq %r15
	movq %es, %r15
	pushq %r15
	movq %ds, %r15
	pushq %r15
	pushq %r14
	pushq %r13
	pushq %r12
	pushq %r11
	pushq %r10
	pushq %r9
	pushq %r8
	pushq %rbp
	pushq %rdi
	pushq %rsi
	pushq %rdx
	pushq %rcx
	pushq %rbx
	pushq %rax
	movq %rsp, %rdi
	call handle_trap_inner
handle_trap_ret:
	popq %rax
	popq %rbx
	popq %rcx
	popq %rdx
	popq %rsi
	popq %rdi
	popq %rbp
	popq %r8
	popq %r9
	popq %r10
	popq %r11
	popq %r12
	popq %r13
	popq %r14
	popq %r15
	movq %r15, %ds
	popq %r15
	movq %r15, %es
	popq %r15
	// Pop trap number and error code
	add $16, %rsp
	iretq
