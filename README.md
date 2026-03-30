# Chess Challenger 7 Rev. B Reverse Engineering Project

Preservation and reverse-engineering project for Chess Challenger 7 Rev. B.

The objective is to preserve this machine by documenting both its software and its hardware, and to make reconstruction of the system possible from that documentation.

## Background

When I was six years old, my father introduced me to this machine, but he only let me use it sparingly. That made me long for it with all the intensity only a child can feel. Almost fifty years later, after my father passed away, my sister sent me the very same game she had carefully kept safe all those years. Playing with it again made me feel that preserving it was more than a technical exercise. It was a way of holding onto a small surviving piece of his presence, and of rescuing not only an object but also the memories, voices, and emotions still attached to it.

That is why I decided to disassemble it and document both its hardware and its firmware with as much care and respect as possible. This also felt worth doing because the Chess Challenger line belongs to a foundational moment in the history of consumer chess computers. Ron Nelson wrote Fidelity's early chess programs and also worked as its hardware engineer, helping shape the machines that made the series commercially successful, with the Z80-based Chess Challenger 7 becoming one of the best-known dedicated chess computers of its era.

It should also be made clear that the original firmware and hardware originated with Fidelity Electronics. If there is any doubt about rights, reuse, or distribution, the licensing section of this document should be read first.

## Goals

### Firmware

- Reconstruct the ROM as readable and maintainable Z80 assembly
- Document the firmware structure and execution flow in detail
- Explain the front-end, search, evaluation, and opening logic
- Rebuild the raw ROM image from source

### Hardware

- Document the board-level hardware and its interaction with the firmware
- Preserve the machine's hardware design through schematics and supporting material
- Make the hardware easier to study, repair, and reproduce

### Preservation

- Keep the project understandable to future readers without requiring the original development context
- Provide a documentation set that can be read independently of the source code
- Preserve both behaviour and implementation details, not just a binary image

## Current Status

The project currently includes:

- A documented main disassembly in [`asm/chess_challenger_7_rev_b.asm`](asm/chess_challenger_7_rev_b.asm)
- A public documentation set in [`docs/`](docs/)
- A build helper in [`tools/build_rom.py`](tools/build_rom.py)
- A build path that already reproduces a raw `4096`-byte ROM image with the expected project hashes

### Planned Additions

The project will also include:

- Hardware schematic
- BOM

## How To Read The Project

The recommended reading order is:

1. [`docs/firmware_overview.md`](docs/firmware_overview.md)
2. [`docs/hardware_and_memory_map.md`](docs/hardware_and_memory_map.md)
3. [`docs/frontend_and_game_flow.md`](docs/frontend_and_game_flow.md)
4. [`docs/search_and_move_generation.md`](docs/search_and_move_generation.md)
5. [`docs/evaluation.md`](docs/evaluation.md)
6. [`docs/opening_system.md`](docs/opening_system.md)
7. [`docs/build_and_verification.md`](docs/build_and_verification.md)
8. [`docs/reference_tables.md`](docs/reference_tables.md)

If you want to jump straight into the source, start with [`asm/chess_challenger_7_rev_b.asm`](asm/chess_challenger_7_rev_b.asm).

## Documentation Map

### Core Documentation

- [`docs/firmware_overview.md`](docs/firmware_overview.md)
  Structural introduction to the ROM and the main execution flow.
- [`docs/hardware_and_memory_map.md`](docs/hardware_and_memory_map.md)
  Ports, RAM layout, `0x88` board representation, sidecar bytes, and threaded records.
- [`docs/frontend_and_game_flow.md`](docs/frontend_and_game_flow.md)
  Cold start, polling loop, debounce, move entry, and front-panel commands.
- [`docs/search_and_move_generation.md`](docs/search_and_move_generation.md)
  Engine handoff, stage windows, threaded records, move generation, and best-move publication.
- [`docs/evaluation.md`](docs/evaluation.md)
  Sidecar pre-evaluation, board sweep, king terms, and final score adjustments.
- [`docs/opening_system.md`](docs/opening_system.md)
  Early front-end lattice, opening families, `CB` computer-first path, and current coverage boundary.
- [`docs/build_and_verification.md`](docs/build_and_verification.md)
  Build target, platform-specific build commands, and required output hashes.
- [`docs/reference_tables.md`](docs/reference_tables.md)
  Quick lookup appendix for key codes, RAM labels, ROM tables, and other constants.

## Repository Layout

- [`asm/`](asm/)
  Main source code of the reconstructed ROM.
- [`docs/`](docs/)
  Public project documentation.
- [`tools/`](tools/)
  Public project helper scripts.
- [`build/`](build/)
  Generated build artifacts.

Additional hardware documentation will be added to the public project structure as it is incorporated.

## Building

Use the build helper:

- Linux: `python3 tools/build_rom.py`
- Windows: `py -3 tools/build_rom.py`

For the exact build target and expected hashes, see [`docs/build_and_verification.md`](docs/build_and_verification.md).

## Licensing

Original material authored for this repository, including documentation, annotations, hardware documentation, and project tooling, is released under GPL-3.0-or-later.

The original Chess Challenger 7 Rev. B firmware remains the copyrighted work of its original rightsholder. This project does not claim ownership of the original firmware and does not re-license it here.

The assembly source in this repository is part of a preservation, study, and reconstruction effort based on that original firmware.

## Notes

This `README.md` is currently focused on project structure, scope, and navigation. Historical background, project history, and additional preservation context can be added here later.
