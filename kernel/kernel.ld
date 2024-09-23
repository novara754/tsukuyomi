ENTRY(_start)

/* Define appropriate program headers for Limine to set up proper paging */
PHDRS
{
    headers PT_PHDR PHDRS;
    text    PT_LOAD FILEHDR PHDRS;
    rodata  PT_LOAD;
    data    PT_LOAD;
}

SECTIONS
{
    /* Limine spec mandates loading at 0xFFFFFFFF80000000 or higher */
    . = 0xffffffff80000000 + SIZEOF_HEADERS;

    .text : {
        *(.text .text*)
    } :text

    /* Move to the next memory page for .rodata */
    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        *(.rodata .rodata*)
    } :rodata

    /* Move to the next memory page for .data */
    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        *(.data .data*)
        /* Place the sections that contain the Limine requests as part of the .data */
        KEEP(*(.requests))
    } :data

    /* NOTE: .bss needs to be the last thing mapped to :data, otherwise lots of */
    /* unnecessary zeros will be written to the binary. */
    .bss : {
        *(.bss .bss*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note*)
        *(.interp)
    }
}
