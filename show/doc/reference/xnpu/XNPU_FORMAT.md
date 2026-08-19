# XUPT-NPU deployment package v1

`*.xnpu` is the stable, target-independent deployment format for hardware ABI
2.  It contains only data needed to load one model plus optional user-space
metadata.  Training checkpoints, Python objects and test inputs are not part of
the package.

All integers are unsigned little-endian.  Offsets are absolute file offsets.
The file and every section start are 16-byte aligned.  Readers must reject
unknown non-zero reserved fields, integer overflow, sections outside the file,
overlapping sections, duplicate singleton sections and required sections they
do not understand.

## Fixed header

The header is 256 bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | magic: `58 4e 50 55 0d 0a 1a 0a` |
| 8 | 2 | package version (`1`) |
| 10 | 2 | header size (`256`) |
| 12 | 4 | flags (zero in v1) |
| 16 | 4 | required hardware ABI |
| 20 | 4 | stable model ID |
| 24 | 4 | task (`1` bbox, `2` classification) |
| 28 | 4 | layer count |
| 32 | 4 | total file size |
| 36 | 4 | section count |
| 40 | 4 | section table offset (`256`) |
| 44 | 4 | section entry size (`32`) |
| 48 | 4 | input mode |
| 52 | 12 | input width, height, channels |
| 64 | 4 | input layout |
| 68 | 4 | input dtype |
| 72 | 4 | input byte count |
| 76 | 12 | output width, height, channels |
| 88 | 4 | output layout |
| 92 | 4 | output dtype |
| 96 | 4 | output/result byte count |
| 100 | 4 | parameter byte count |
| 104 | 4 | scratch byte requirement |
| 108 | 4 | required driver capability bits |
| 112 | 32 | package SHA-256 |
| 144 | 112 | reserved, all zero |

Input mode, layout, dtype and capability values intentionally match
`linux/xupt_npu.h`.  Shape dimensions use `width, height, channels` order.

To calculate the package SHA-256, hash the complete file after replacing bytes
112 through 143 with zero.  Then store that digest in the field.  This rule
makes the package deterministic and avoids a self-referential digest.

## Section table

The table immediately follows the fixed header.  Each 32-byte entry contains:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | section type |
| 4 | 4 | flags |
| 8 | 4 | data offset |
| 12 | 4 | data length |
| 16 | 4 | IEEE CRC-32 of data |
| 20 | 12 | reserved, all zero |

Section flag bit 0 means required.  Bit 1 means UTF-8 text.  Bit 2 means
canonical JSON.  Sections are ordered by type:

| Type | Name | Cardinality | Encoding |
| ---: | --- | --- | --- |
| 1 | descriptors | exactly one, required | `layer_count * 8` LE `u32` words |
| 2 | parameter image | exactly one, required | hardware parameter bytes |
| 3 | model name | exactly one, required | non-empty UTF-8, no NUL |
| 4 | labels | zero or one | newline-separated UTF-8, final newline |
| 5 | metadata | zero or one | canonical UTF-8 JSON |

The parameter section length must equal `parameter byte count`; descriptor
length must equal `layer count * 32`.  The package does not carry test fixtures:
the catalog packer emits those as independent `.bin` files and a regression
manifest.

## Determinism and compatibility

The reference packer sorts sections by numeric type, emits canonical JSON
(`sort_keys`, compact separators), uses fixed zero padding and never records a
timestamp or local path.  Repacking the same checked-in assets must produce
byte-identical files.

A v1 reader accepts only package version 1 and hardware ABI 2.  Future
compatible extensions require a new section type with the required flag clear;
an incompatible header change requires a new package version.
