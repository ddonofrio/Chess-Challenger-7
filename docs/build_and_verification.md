# Build and Verification

## Purpose

This document defines the build target and the verification contract for the project.

The goal is not merely to assemble a readable source file. The goal is to rebuild a raw ROM image.

## Scope

This file describes:

- What the build output must be
- Which build command to use on Linux
- Which build command to use on Windows
- Which hashes the generated binary must have

It does not describe internal comparison steps or working-reference files.

## Build Target

The build target is a raw Z80 ROM image with these properties:

| Property | Required value |
| --- | --- |
| origin | `0000h` |
| size | `4096` bytes |
| format | raw binary |
| output path | `build/chess_challenger_7_rev_b.bin` |

The source file is [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

The build helper is [`build_rom.py`](../tools/build_rom.py).

The script creates the `build/` directory automatically if it does not already exist and writes the generated ROM image there. That directory is a build output location, not part of the source material that needs to be versioned.

### Linux

Install the assembler helper once:

```bash
python3 -m pip install pyz80
```

Build the ROM:

```bash
python3 tools/build_rom.py
```

### Windows

Install the assembler helper once:

```powershell
py -3 -m pip install pyz80
```

Build the ROM:

```powershell
py -3 tools/build_rom.py
```

## Verification

The generated binary must have these hashes:

| Algorithm | Expected value |
| --- | --- |
| MD5 | `B4EFE4001D41652A2016115BE7925351` |
| SHA1 | `9B12BC442FCCEE40F4D8500C792BC9D886C5E1A5` |
