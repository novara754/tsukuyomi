.section .text
.global switchContext
switchContext:
	pushq %r15
	pushq %r14
	pushq %r13
	pushq %r12
	pushq %rbp
	pushq %rbx

	mov %rsp, (%rdi)
	mov %rsi, %rsp

	popq %rbx
	popq %rbp
	popq %r12
	popq %r13
	popq %r14
	popq %r15
	ret
