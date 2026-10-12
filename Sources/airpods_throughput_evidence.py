"""Export reproducible STFW 9.1.42 heatmap evidence; requires capstone."""

import argparse
import hashlib
import json
import struct
from pathlib import Path

from capstone import CS_ARCH_ARM, CS_MODE_LITTLE_ENDIAN, CS_MODE_THUMB, Cs


BASE = 0x08001800
EXPECTED_SHA256 = "13486d90ee8c46cb0f0dc3c4ad865ea5fdb5b9cce2dfb5fe6aa48eec1fab94be"
RANGES = [
    ("initialize matrices and bind tier tables", 0x080521DC, 0x080522DC),
    ("elapsed milliseconds to rounded seconds", 0x0805278C, 0x080527C6),
    ("bin battery SOC, temperature and current", 0x080527CE, 0x0805282E),
    ("accumulate battery current times seconds", 0x080528B2, 0x080528DE),
    ("divide accumulated mA.seconds by 60 and store", 0x08052928, 0x0805299C),
    ("expand stored 24-bit heatmap fields without scaling", 0x08040D14, 0x08040DA4),
    ("current-state classifier", 0x08053D88, 0x08053DC0),
    ("tier lookup", 0x08056FA2, 0x08056FCC),
    ("24-bit saturating storage", 0x080572F0, 0x08057314),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("firmware", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    binary = args.firmware.read_bytes()
    digest = hashlib.sha256(binary).hexdigest()
    if digest != EXPECTED_SHA256:
        parser.error("This address map requires the exact analyzed STFW 9.1.42 image.")

    def values(address, fmt):
        return struct.unpack_from(fmt, binary, address - BASE)

    soc = values(0x0806E84C, "<9H")
    temperature = values(0x0806E85E, "<5H")
    milliseconds_per_second = values(0x080526C8, "<f")[0]
    assert soc == (0, 10, 20, 40, 60, 80, 85, 90, 95)
    assert temperature == (0, 20, 27, 35, 42)
    assert milliseconds_per_second == 1000
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {
        "sha256": digest,
        "load_base": hex(BASE),
        "milliseconds_per_second": milliseconds_per_second,
        "soc_lower_bounds_percent": soc,
        "temperature_lower_bounds_C": temperature,
        "first_temperature_bucket": "below 20 C, including negative values",
        "raw_unit": "mA.min",
        "raw_to_mAh_divisor": 60,
        "example_raw": 144027,
        "example_mAh": 144027 / 60,
        "example_region": "20 <= SOC < 40 percent; 27 <= battery temperature < 35 C",
    }
    (args.output / "evidence.json").write_text(json.dumps(metadata, indent=2) + "\n")
    disassembler = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_LITTLE_ENDIAN)
    with (args.output / "evidence-disassembly.txt").open("w") as output:
        for label, start, end in RANGES:
            output.write(f"\n{label}\n")
            for instruction in disassembler.disasm(binary[start - BASE:end - BASE], start):
                output.write(f"{instruction.address:08x}  {instruction.mnemonic} {instruction.op_str}\n")
    print("PASS: firmware hash, time scale, SOC / temperature tier tables")
    print("144027 mA.min / 60 = 2400.45 mAh")


if __name__ == "__main__":
    main()
