OUTPUT_ARCH(loongarch)
ENTRY(_start)

SECTIONS
{
  . = 0xa0100000;
  .text : ALIGN(16)
  {
    KEEP(*(.text.start))
    *(.text .text.*)
  }
}
