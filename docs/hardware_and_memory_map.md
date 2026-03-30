# Hardware and Memory Map

## Purpose

This document describes the firmware-facing machine model:

- I/O ports
- Display, keypad, and buzzer wiring as seen by the ROM
- RAM layout
- `0x88` board representation
- Piece, sidecar, and threaded-record formats

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

For the high-level program flow, start with [`./firmware_overview.md`](./firmware_overview.md).

## Scope

This file is about the structures that the firmware reads and writes.

It does not try to explain:

- The front-end command flow in detail
- The staged search algorithm
- The full evaluation pipeline
- The named opening families

Those topics are covered in separate documents.

## External Interface

### Effective Port Model

From the firmware's point of view, the hardware is exposed through a very small port space mirrored over `00h-07h`.

In practice, the ROM relies on two patterns:

- Direct writes and reads through port `07h` for multiplex control and keypad scanning
- Serial bit output through ports `07h..00h` for the NE591 segment latch via `write_ne591_pattern`

The important consequence is that the display, keypad, LEDs, and buzzer are not managed by independent controllers. They all share the same tight polling rhythm.

### Display and Keypad Multiplex

The main polling loop writes a scan byte to port `07h` and immediately reads back the keypad rows through the same path.

Within that scan byte:

- `D0-D3` select the active display digit and keypad column
- `D4-D5` carry the `CHECK` / `I LOSE` indicator bits
- `D7` participates in the segment-latch path used by `write_ne591_pattern`

The four visible digits therefore share their timing with keypad scanning. If the polling loop stops, both display refresh and input sampling stop with it.

### NE591 Segment Latch

Segment patterns are emitted one bit at a time by `write_ne591_pattern`.

That routine is the bridge between the firmware's display buffer and the real segment hardware:

- The ROM prepares one segment byte in `A`
- `write_ne591_pattern` clocks the eight bits out through ports `07h..00h`
- The active digit select is then combined with the LED bits and sent back through port `07h`

This is why visible rendering is split across two phases:

1. load segment data into the NE591 path
2. enable one digit plus the `CHECK` / `I LOSE` lines for a short dwell time

### Buzzer

The buzzer is driven through the same output path.

The routine `beep_if_enabled` generates a short tone by toggling port bit `7` in a busy loop. No separate interrupt, timer, or sound generator is involved.

## Memory Map

### ROM

The firmware image occupies `0000h-0FFFh`, for a total of `4096` bytes.

That space contains:

- Reset and helper vectors
- UI and engine code
- Display/message tables
- The front-end state lattice
- Level descriptors
- Compact move-generation microcode
- Evaluation and king-distance tables

### RAM

The physical RAM window is `3000h-30FFh`.

Within that page, the firmware uses several distinct regions:

| Range | Purpose |
| --- | --- |
| `3000h-3077h` | live `0x88` board |
| `3080h-3094h` | front-end state, display bytes, move bytes, level state, search scheduling |
| `30ADh-30B7h` | overlapping threaded early-search records |
| `30B8h-30E3h` | staged search workspace and move-record pool |
| `30E4h-30E5h` | blink / timing / tie-break helper bytes |
| `30E6h+` | compact script slots |

The rest of the page is used as scratch or as part of those larger working areas.

## Key RAM Regions

### Board Region

`ram_board_0x88` at `3000h` is the live board.

Only `3000h-3077h` are meaningful board cells. The holes created by the `0x88` layout are used as fast off-board sentinels.

### Front-End Globals

The block at `3080h-3094h` is the firmware's main shared state band.

Some particularly important bytes are:

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_level` | `3080h` | selected front-panel level |
| `ram_phase_turn_counter` | `3081h` | monotonic game-progress counter |
| `ram_frontend_flags0` | `3082h` | front-end / setup flags |
| `ram_frontend_flags1` | `3083h` | mode and display flags |
| `ram_board_cursor_or_material` | `3084h` | board-review cursor in UI, material accumulator in search |
| `ram_led_select_bits` | `3085h` | `CHECK` / `I LOSE` output bits |
| `ram_move_to_square` | `3086h` | visible `TO` square |
| `ram_move_from_square` | `3087h` | visible `FROM` square |
| `ram_disp_from_lo`..`ram_disp_to_hi` | `3088h-308Bh` | display buffer in UI, reused as score words during search |
| `ram_key_state` | `308Ch` | front-end state-lattice offset |
| `ram_schedule_base_offset` | `308Eh` | level-selected search schedule base |
| `ram_schedule_stage_mask` | `308Fh` | active search-stage mask |
| `ram_stage_route_mask` | `3090h` | alternate-route mask for `search_driver` |
| `ram_search_stage_cursor` | `3091h` | live rotating stage bit |
| `ram_best_move_from_tagged` | `3092h` | tagged best `FROM` square |
| `ram_best_move_to_tagged` | `3093h` | tagged best `TO` square |
| `ram_prev_move_to_square` | `3094h` | previous destination square |

### Threaded Early-Search Records

The lower and upper early-search records overlap:

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_root_record_base` | `30ADh` | lower/root record base |
| `ram_root_from_tagged` | `30AEh` | root tagged `FROM` |
| `ram_root_to_tagged` | `30AFh` | root tagged `TO` |
| `ram_reply_record_descriptor` | `30B2h` | shared boundary byte between the two records |
| `ram_reply_from_tagged` | `30B3h` | reply tagged `FROM` |
| `ram_reply_to_tagged` | `30B4h` | reply tagged `TO` |
| `ram_reply_continuation_tag` | `30B7h` | reply continuation / dispatch byte |

This overlap is deliberate. The byte at `30B2h` closes the lower record and opens the upper one.

### Search Workspace

The staged move-record pool begins at `30BBh`.

The widest search window reaches `30E2h`, with `30E3h` acting as the sentinel above the widest pool. The fixed guard band just below it begins at `30B8h`.

## `0x88` Board Representation

### Why `0x88`

The board uses the classic `0x88` layout:

- File is stored in the low nibble
- Rank is stored in the high nibble
- Valid board squares satisfy `(square & 88h) == 0`

This gives the engine two major advantages:

- Directional stepping is just signed byte addition
- Off-board detection is one `AND 88h` test

### Coordinate Examples

The normal input path builds the visible move bytes directly in `0x88`.

One concrete example used throughout the project is:

- `e2 = 64h`
- `e4 = 44h`

So the visible move `e2-e4` is represented as `64h -> 44h` before any later tagging is applied.

### Initial Board Template

The live board is built during `cold_start` from `tbl_initial_board_hi_nibbles`.

That table stores more than raw starting pieces:

- The high nibble becomes the signed piece code after biasing by `F8h`
- The low nibble survives as a compact opening/development square-class byte

This explains why empty starting ranks are not uniform in the ROM template. For example, row 2 contains `81h`, `82h`, `83h`, and `84h`, but all of them still produce empty squares because the high nibble is `8`.

## Piece Format

The live board uses a compact signed piece code:

| Value | Meaning |
| --- | --- |
| `00h` | empty |
| `01h` | pawn |
| `02h` | knight |
| `03h` | bishop |
| `04h` | rook |
| `05h` | queen |
| `06h` | king |

Negative values represent the same piece types for the opposite side.

In practical terms, the board coding is:

| Signed code | Meaning |
| --- | --- |
| `+01` | white pawn |
| `+02` | white knight |
| `+03` | white bishop |
| `+04` | white rook |
| `+05` | white queen |
| `+06` | white king |
| `-01` | black pawn |
| `-02` | black knight |
| `-03` | black bishop |
| `-04` | black rook |
| `-05` | black queen |
| `-06` | black king |

This choice lets the firmware:

- Test occupancy with `OR A`
- Test side with `BIT 7`
- Turn hostile pieces into magnitudes with `CPL / INC A`

It is useful to keep this separate from the evaluator's material table.

The board stores piece identity as `Â±1..Â±6`, but the material lookup later maps those identities to weighted values:

| Piece | Material value used by the lookup table |
| --- | --- |
| pawn | `1` |
| knight | `3` |
| bishop | `3` |
| rook | `5` |
| queen | `9` |
| king | `9` |

## Sidecar Format

The `0x88` holes are reused as a packed sidecar map consumed by move generation and evaluation.

Each sidecar byte is structured as:

| Bits | Meaning |
| --- | --- |
| `7-6` | positive-side control count |
| `5-4` | negative-side control count |
| `3-2` | positive-side least-valuable-attacker class |
| `1-0` | negative-side least-valuable-attacker class |

This gives the evaluator a coarse picture of:

- How many pieces attack the square from each side
- Which side has the cheaper first attacker

The sidecar bytes are not a second board. They are a compressed tactical summary layered on top of the real board.

## Threaded Record Format

The early-search path uses 6-byte threaded records in page `30h`.

The layout is:

| Offset | Meaning |
| --- | --- |
| `+0` | descriptor / result byte |
| `+1` | tagged `FROM` square |
| `+2` | tagged `TO` square |
| `+3` | copied low display/search byte |
| `+4` | copied high display/search byte |
| `+5` | continuation / dispatch byte |

Two details matter:

1. The move bytes are still `0x88` squares; later code strips tags with `AND 77h`.
2. The `+5` byte is a control-flow continuation byte used by the threaded early-game path.

The record is therefore both data and control state at the same time.

## Display Buffer Format

The front-end shows the active move window through four display bytes in `3088h-308Bh`.

`rebuild_from_to_display` renders:

- High byte first
- Low byte second

So the left display window corresponds to `ram_move_from_square` and the right one to `ram_move_to_square`, even though the pair is stored in RAM as `3086h = TO`, `3087h = FROM`.

## Summary

The most important structural idea in this ROM is that one page of RAM does almost everything:

- It holds the live `0x88` board
- It holds front-end state
- It holds visible move bytes
- It holds threaded opening/search records
- It holds the staged move-record pool

That is why the firmware feels dense. The same addresses are reused by the polling loop, the command logic, the engine handoff, and the evaluator with very little abstraction in between.
