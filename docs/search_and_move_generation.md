# Search and Move Generation

## Purpose

This document explains how the firmware moves from an accepted visible move into candidate generation, staged search, and best-move publication.

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

For the front-end path that leads into this engine handoff, see [`./frontend_and_game_flow.md`](./frontend_and_game_flow.md).

## Scope

This file focuses on:

- The front-end to engine handoff
- Staged search windows
- Threaded early-search records
- Piece-family generation
- Compact piece scripts
- Publication of the best move

The evaluation logic itself is covered in [`./evaluation.md`](./evaluation.md).

## Engine Handoff

The front-end hands control to the engine through `start_engine_move_or_search`.

At that point the firmware has already decided one of three things:

- A visible move was accepted by the front-end lattice
- A mismatched move must be pushed into the generic engine path
- A command path such as `CB` or `PB` is seeding a special startup entry

The handoff code then:

1. stores the move pair
2. applies it to the live `0x88` board if needed
3. seeds or updates the threaded record band in page `30h`
4. loads the current level descriptor
5. jumps into `search_driver`

The engine therefore does not build its own abstract position object. It reuses the move bytes and working state prepared by the front-end.

## Search Driver

`search_driver` is the main dispatcher of the move-selection core.

Its job is to choose among three broad paths:

- Staged search through the page-`30h` move-record pool
- Replay of a threaded early-game record
- Generic piece-based branching

The choice depends on:

- The current one-bit stage cursor in `ram_search_stage_cursor`
- The active-stage mask in `ram_schedule_stage_mask`
- The alternate-route mask in `ram_stage_route_mask`
- Local flags carried in `C`

This is a compact dispatcher, not a deep call tree. Much of the ROM's density comes from the fact that the same routine handles staging, threaded replay, and generic search entry.

## Stage Windows

### Level-Dependent Schedule

The schedule for the staged search is loaded from `tbl_level_setup`.

Its live RAM form is spread across:

- `ram_schedule_base_offset`
- `ram_schedule_stage_mask`
- `ram_stage_route_mask`
- `ram_search_stage_cursor`

The firmware does not treat levels as a simple depth number. Instead, each level chooses:

- Which stage descriptors are active
- Which stages use the alternate route in `search_driver`
- Which record window is active for the current stage bit

### Decoding a Window

`decode_stage_record_window` and `pick_stage_descriptor_pair` decode the active page-`30h` move-record window for the current stage.

The returned pair means:

- First byte: base address within page `30h`
- Second byte: record count

The count is then converted into a byte length by shifting left twice, because each record is four bytes.

### Practical Window Shapes

The staged workspace is built around the shared pool at `30BBh-30E2h`.

The main nested windows used by the engine are:

- A 10-record window spanning `30BBh-30E2h`
- A 5-record prefix spanning `30BBh-30CEh`
- A 2-record inner window spanning `30BDh-30C4h`

These windows are not independent arrays. They are nested views over one shared move-record pool.

## Threaded Early-Search Records

### Layout

The early-game handoff uses overlapping 6-byte threaded records at `30ADh-30B7h`.

Each record has this form:

| Offset | Meaning |
| --- | --- |
| `+0` | descriptor / result |
| `+1` | tagged `FROM` |
| `+2` | tagged `TO` |
| `+3` | copied low word byte |
| `+4` | copied high word byte |
| `+5` | continuation / dispatch byte |

The overlap point at `30B2h` is the key structural detail:

- It is `+5` of the lower/root record
- It is `+0` of the upper/reply record

### Tagged Squares

The record move bytes are still `0x88` squares.

Later paths strip their tags with `AND 77h`, so the threaded path is not inventing a second board representation. It is carrying ordinary squares plus a small amount of control metadata in the same byte.

### Continuation Bytes

The `+5` byte is a continuation tag used by the threaded early-game path.

Certain values are special:

- `5Eh`
- `5Fh`
- `60h`

These values are the tail bytes of the tiny trampoline at `015Eh-0160h`, and they route execution back into the generic search branch rather than continuing the threaded early path.

This is one of the strongest signs that the firmware's opening behaviour is encoded as compact control flow, not as a flat named-opening table.

## Candidate Replay and Comparison

When a threaded record survives the continuation gate, `search_driver`:

1. normalizes the record pointer
2. decodes the active stage window
3. materializes the tagged `FROM/TO` pair
4. compares that candidate against the current window
5. resumes the generic evaluator/comparator path

So even special early-game candidates are eventually folded back into the normal candidate-comparison machinery.

That shared machinery is why the best-move path does not split cleanly into "opening mode" and "normal mode". Early candidates are replayed into the ordinary search pipeline.

## Generic Move Generation

If the threaded path is not taken, search eventually falls through to `search_branch_when_piece_present`.

This is the main per-piece branching point.

Its inputs are:

- The live board square
- The current side bits
- Castling-disable information for king-family handling
- The compact per-piece dispatch table in page `00h`

The firmware then reduces the current side and piece information to a compact family selector and dispatches into the page-`01` script families.

## Piece Script Families

The main script-entry families are:

| Entry | Family |
| --- | --- |
| `0100h` | pawn / first-rank special microcode |
| `0176h` | knight |
| `0190h` | king |
| `01AAh` | rook / queen orthogonal |
| `01C6h` | bishop / queen diagonal |

The per-piece class selection is not hard-coded as a large switch statement. It is data-driven by the helper bytes around `tbl_piece_property`.

## Compact Piece Scripts

### Why the Scripts Matter

The ROM does not encode all move traversal as long explicit routines.

Instead, it uses:

- Tiny page-`01` script fragments
- Shared postprocess helpers
- A compact interpreter
- Small script slots in RAM

This is executable microcode, not just passive tables.

### Direction Walking

For non-pawn families, `walk_piece_script_direction_loop` steps through one direction family at a time and collects whether one, two, or three postprocess deltas still need to be emitted.

The script walker checks:

- Board boundaries
- Sidecar occupancy/control nibbles
- Occupancy and colour of the target square
- Whether a follow-up postprocess scriptlet is required

### Vector Interpreter

`vector_script_interpreter` is the core interpreter for this compact script format.

It repeatedly:

1. fetches one signed delta byte
2. tests the target square
3. continues until a terminal condition is reached
4. reserves a RAM script slot if a target survives the filters

The result is a move/attack generator that is small in ROM but highly table-driven.

## Publication of the Best Move

The firmware publishes the best move in two layers.

### Tagged Best Pair

During search, the current best tagged pair is copied into:

- `ram_best_move_from_tagged`
- `ram_best_move_to_tagged`

These bytes are often available before the visible move window is fully rebuilt.

### Visible Move Window

The final publication path then:

1. selects the winning record window
2. strips any move tags
3. writes the visible `FROM/TO` pair back into `3087h/3086h`
4. rebuilds the display buffer
5. updates post-search status through `post_search_status_update`

The visible move window is therefore the last step of publication, not the internal best-candidate format used throughout search.

## Summary

The search and move-generation core is best understood as a layered but shared system:

- The front-end seeds the move bytes and handoff records
- Level descriptors choose staged record windows
- `search_driver` routes among staged search, threaded replay, and generic branching
- Compact page-`01` scripts generate piece-family movement
- Best-move publication writes both tagged internal bytes and a visible `FROM/TO` pair

The key design choice is reuse. Early-game control, generic search, and final publication all operate over the same small set of RAM structures in page `30h`.
