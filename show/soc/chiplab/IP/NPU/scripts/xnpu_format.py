#!/usr/bin/env python3
"""Reference reader/writer primitives for deterministic XNPU v1 packages."""

from __future__ import annotations

import binascii
import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Tuple

MAGIC = b"XNPU\r\n\x1a\n"
VERSION = 1
HEADER_SIZE = 256
SECTION_ENTRY_SIZE = 32
HASH_OFFSET = 112
HASH_SIZE = 32
ALIGNMENT = 16

SECTION_DESCRIPTORS = 1
SECTION_PARAMETERS = 2
SECTION_NAME = 3
SECTION_LABELS = 4
SECTION_METADATA = 5

SECTION_REQUIRED = 1 << 0
SECTION_UTF8 = 1 << 1
SECTION_JSON = 1 << 2

TASK_BBOX = 1
TASK_CLASSIFICATION = 2

HEADER_U32_FIELDS = (
    "flags",
    "hardware_abi",
    "model_id",
    "task",
    "layer_count",
    "file_size",
    "section_count",
    "section_table_offset",
    "section_entry_size",
    "input_mode",
    "input_width",
    "input_height",
    "input_channels",
    "input_layout",
    "input_dtype",
    "input_bytes",
    "output_width",
    "output_height",
    "output_channels",
    "output_layout",
    "output_dtype",
    "output_bytes",
    "parameter_bytes",
    "scratch_bytes",
    "required_caps",
)


class FormatError(ValueError):
    """Package is malformed or fails an integrity check."""


@dataclass(frozen=True)
class Section:
    type: int
    flags: int
    offset: int
    data: bytes
    crc32: int


@dataclass(frozen=True)
class Package:
    header: Dict[str, int]
    sha256: bytes
    sections: Dict[int, Section]
    data: bytes

    def section(self, section_type: int) -> bytes:
        try:
            return self.sections[section_type].data
        except KeyError as exc:
            raise FormatError(f"missing section type {section_type}") from exc


def align(value: int, alignment: int = ALIGNMENT) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def package_digest(data: bytes) -> bytes:
    if len(data) < HASH_OFFSET + HASH_SIZE:
        raise FormatError("file is too short for package hash")
    digest_input = bytearray(data)
    digest_input[HASH_OFFSET : HASH_OFFSET + HASH_SIZE] = bytes(HASH_SIZE)
    return hashlib.sha256(digest_input).digest()


def build_package(header: Dict[str, int],
                  sections: Iterable[Tuple[int, int, bytes]]) -> bytes:
    ordered = sorted((int(t), int(f), bytes(d)) for t, f, d in sections)
    if not ordered or len({item[0] for item in ordered}) != len(ordered):
        raise FormatError("section types must be unique")
    table_end = HEADER_SIZE + len(ordered) * SECTION_ENTRY_SIZE
    cursor = align(table_end)
    entries = []
    payloads = []
    for section_type, flags, data in ordered:
        entries.append((section_type, flags, cursor, len(data), crc32(data)))
        payloads.append((cursor, data))
        cursor = align(cursor + len(data))

    values = dict(header)
    values.update(
        file_size=cursor,
        section_count=len(ordered),
        section_table_offset=HEADER_SIZE,
        section_entry_size=SECTION_ENTRY_SIZE,
    )
    missing = [name for name in HEADER_U32_FIELDS if name not in values]
    if missing:
        raise FormatError("missing header fields: " + ", ".join(missing))

    output = bytearray(cursor)
    output[:8] = MAGIC
    struct.pack_into("<HH", output, 8, VERSION, HEADER_SIZE)
    struct.pack_into(
        "<" + "I" * len(HEADER_U32_FIELDS),
        output,
        12,
        *(values[name] for name in HEADER_U32_FIELDS),
    )
    for index, (section_type, flags, offset, length, checksum) in enumerate(entries):
        struct.pack_into(
            "<8I",
            output,
            HEADER_SIZE + index * SECTION_ENTRY_SIZE,
            section_type,
            flags,
            offset,
            length,
            checksum,
            0,
            0,
            0,
        )
    for offset, data in payloads:
        output[offset : offset + len(data)] = data
    output[HASH_OFFSET : HASH_OFFSET + HASH_SIZE] = package_digest(output)
    return bytes(output)


def parse_package(data: bytes, verify_integrity: bool = True) -> Package:
    if len(data) < HEADER_SIZE:
        raise FormatError("file shorter than fixed header")
    if data[:8] != MAGIC:
        raise FormatError("bad magic")
    version, header_size = struct.unpack_from("<HH", data, 8)
    if version != VERSION:
        raise FormatError(f"unsupported package version {version}")
    if header_size != HEADER_SIZE:
        raise FormatError(f"unexpected header size {header_size}")
    values = struct.unpack_from("<" + "I" * len(HEADER_U32_FIELDS), data, 12)
    header = dict(zip(HEADER_U32_FIELDS, values))
    if header["flags"]:
        raise FormatError("unknown header flags")
    if header["file_size"] != len(data):
        raise FormatError("file size field does not match input")
    if header["section_table_offset"] != HEADER_SIZE:
        raise FormatError("unexpected section table offset")
    if header["section_entry_size"] != SECTION_ENTRY_SIZE:
        raise FormatError("unexpected section entry size")
    if any(data[144:HEADER_SIZE]):
        raise FormatError("non-zero reserved header bytes")
    count = header["section_count"]
    if count == 0 or count > 32:
        raise FormatError("invalid section count")
    table_end = HEADER_SIZE + count * SECTION_ENTRY_SIZE
    if table_end > len(data):
        raise FormatError("section table exceeds file")

    sections: Dict[int, Section] = {}
    intervals = []
    last_type = 0
    known = {
        SECTION_DESCRIPTORS,
        SECTION_PARAMETERS,
        SECTION_NAME,
        SECTION_LABELS,
        SECTION_METADATA,
    }
    for index in range(count):
        entry = struct.unpack_from("<8I", data, HEADER_SIZE + index * SECTION_ENTRY_SIZE)
        section_type, flags, offset, length, checksum, r0, r1, r2 = entry
        if r0 or r1 or r2:
            raise FormatError("non-zero reserved section entry")
        if section_type <= last_type:
            raise FormatError("sections are not in canonical type order")
        last_type = section_type
        if flags & ~(SECTION_REQUIRED | SECTION_UTF8 | SECTION_JSON):
            raise FormatError("unknown section flags")
        if section_type not in known and flags & SECTION_REQUIRED:
            raise FormatError(f"unknown required section {section_type}")
        if offset % ALIGNMENT or offset < align(table_end):
            raise FormatError("invalid section offset or alignment")
        end = offset + length
        if end < offset or end > len(data):
            raise FormatError("section exceeds file")
        intervals.append((offset, end))
        section_data = data[offset:end]
        if verify_integrity and crc32(section_data) != checksum:
            raise FormatError(f"section {section_type} CRC-32 mismatch")
        if section_type in sections:
            raise FormatError(f"duplicate section {section_type}")
        sections[section_type] = Section(
            section_type, flags, offset, section_data, checksum
        )
    intervals.sort()
    for previous, current in zip(intervals, intervals[1:]):
        if previous[1] > current[0]:
            raise FormatError("overlapping sections")

    for required in (SECTION_DESCRIPTORS, SECTION_PARAMETERS, SECTION_NAME):
        if required not in sections or not sections[required].flags & SECTION_REQUIRED:
            raise FormatError(f"missing required section {required}")
    if len(sections[SECTION_DESCRIPTORS].data) != header["layer_count"] * 32:
        raise FormatError("descriptor length does not match layer count")
    if len(sections[SECTION_PARAMETERS].data) != header["parameter_bytes"]:
        raise FormatError("parameter length does not match header")
    name = sections[SECTION_NAME].data
    if not name or b"\0" in name:
        raise FormatError("invalid model name")
    for section_type in (SECTION_NAME, SECTION_LABELS, SECTION_METADATA):
        if section_type in sections:
            try:
                sections[section_type].data.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise FormatError(f"section {section_type} is not UTF-8") from exc
    stored_digest = data[HASH_OFFSET : HASH_OFFSET + HASH_SIZE]
    if verify_integrity and package_digest(data) != stored_digest:
        raise FormatError("package SHA-256 mismatch")
    return Package(header, stored_digest, sections, bytes(data))


def load_package(path: Path, verify_integrity: bool = True) -> Package:
    return parse_package(Path(path).read_bytes(), verify_integrity)
