"""
Build helper for the Chess Challenger 7 Rev. B ROM.

This script assembles ``asm/chess_challenger_7_rev_b.asm`` into the raw
``build/chess_challenger_7_rev_b.bin`` image expected by the project.
It also prints the size, MD5, and SHA1 of the generated ROM image.

Created by Diego D'Onofrio.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


ASM_NAME = "chess_challenger_7_rev_b.asm"
TEMP_NAME = "chess_challenger_7_rev_b.pyz80.asm"
BIN_NAME = "chess_challenger_7_rev_b.bin"


def split_code_and_comment(line: str) -> tuple[str, str]:
    in_quote = False
    for index, char in enumerate(line):
        if char == '"':
            in_quote = not in_quote
        elif not in_quote and char in ";#":
            return line[:index], line[index:]
    return line, ""


def normalize_code_part(code: str) -> str:
    equ_match = re.match(r"^(\s*)([A-Za-z_@.][A-Za-z0-9_@.]*)\s+equ\b(.*)$", code, re.IGNORECASE)
    if equ_match:
        indent, symbol, tail = equ_match.groups()
        code = f"{indent}{symbol}: equ{tail}"

    code = re.sub(r"(?<![A-Za-z0-9_])([0-9A-Fa-f]+)h\b", r"0x\1", code)
    return code


def normalize_source(text: str) -> str:
    normalized_lines: list[str] = []
    for line in text.splitlines():
        code, comment = split_code_and_comment(line)
        normalized_lines.append(normalize_code_part(code) + comment)
    return "\n".join(normalized_lines) + "\n"


def find_pyz80() -> str:
    direct = shutil.which("pyz80")
    if direct:
        return direct

    exe_dir = Path(sys.executable).resolve().parent
    candidates = [
        exe_dir / "pyz80",
        exe_dir / "pyz80.exe",
        exe_dir.parent / "Scripts" / "pyz80.exe",
        exe_dir.parent / "Scripts" / "pyz80",
        exe_dir / "Scripts" / "pyz80.exe",
        exe_dir / "Scripts" / "pyz80",
    ]

    for candidate in candidates:
        if candidate.exists():
            return str(candidate)

    raise FileNotFoundError(
        "pyz80 was not found. Install it with 'python3 -m pip install pyz80' on Linux "
        "or 'py -3 -m pip install pyz80' on Windows."
    )


def file_hash(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    digest.update(path.read_bytes())
    return digest.hexdigest().upper()


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    asm_path = root / "asm" / ASM_NAME
    build_dir = root / "build"
    temp_asm_path = build_dir / TEMP_NAME
    output_bin_path = build_dir / BIN_NAME

    build_dir.mkdir(parents=True, exist_ok=True)

    source_text = asm_path.read_text(encoding="utf-8-sig")
    temp_asm_path.write_text(normalize_source(source_text), encoding="utf-8", newline="\n")

    pyz80 = find_pyz80()
    command = [pyz80, f"--obj={output_bin_path}", str(temp_asm_path)]
    subprocess.run(command, cwd=root, check=True)

    print(f"Output: {output_bin_path}")
    print(f"Size:   {output_bin_path.stat().st_size} bytes")
    print(f"MD5:    {file_hash(output_bin_path, 'md5')}")
    print(f"SHA1:   {file_hash(output_bin_path, 'sha1')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
