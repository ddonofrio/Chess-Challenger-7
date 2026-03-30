# Opening System

## Purpose

This document explains how the firmware controls the early game and how the currently mapped opening families fit into that control structure.

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

For the general front-end flow and search machinery, see:

- [`./frontend_and_game_flow.md`](./frontend_and_game_flow.md)
- [`./search_and_move_generation.md`](./search_and_move_generation.md)

## Scope

This file covers:

- The early front-end state lattice
- Level-dependent opening families
- The `CB` computer-first path
- The named opening families currently mapped in the project
- The present coverage boundary

It is important to read this system as part of the firmware, not as a separate "opening book mode".

## Architectural Overview

The ROM clearly distinguishes early-game behaviour from later generic search, but it does not do so with a flat named-opening table.

The early system is built out of four cooperating structures:

- The front-end state lattice in page `02`
- The monotonic game-progress counter at `3081h`
- The threaded early-search records in page `30h`
- The compact page-`01` microcode and continuation bytes

So the opening system is best understood as an early control layer sitting on top of the same engine machinery used later in the game.

## Early-Game Gates

Two progress gates are especially important:

- `23h` is the main early-game cutoff
- `26h` is a slightly later cutoff used by development/home-square bias

Both are driven from `ram_phase_turn_counter`.

This counter starts at `1` and advances on committed board transitions. The front-end lattice, the evaluation bias, and the early threaded handoff all read that same progress signal.

## Front-End State Lattice

### `ram_key_state` as Lattice Offset

`ram_key_state` is not just a key code. It is the low-byte offset into the page-`02` front-end state lattice rooted at `tbl_frontend_state_phase_pairs`.

The lattice lookup combines:

- The current `ram_key_state`
- A four-byte phase stride derived from `ram_phase_turn_counter`
- The tagged `DE` pair fetched from the table

### Tagged Transition Pairs

Each fetched `DE` pair is a transition descriptor, not merely a plain `FROM/TO` pair.

Its tags can request:

- Literal move comparison
- Accept-without-literal-compare
- Retry-family advance
- Forced handoff through `FFh`
- Immediate `CHECK` indication

This is the reason the early opening system is inseparable from the front-end. The same table that validates visible move entry also steers the early-game families.

## Root Families in the Lattice

The current project mapping identifies these important root offsets:

| Offset | Family |
| --- | --- |
| `FCh` | White king-pawn family |
| `54h` | White queen-pawn family |
| `FEh` | Black `...e5` family |
| `3Eh` | Sicilian family |
| `1Eh` | French family |
| `56h` | `...d5 / ...e6` development family |

There are also follow-up and handoff offsets such as:

- `38h`
- `F8h`
- `1Ah`
- `18h`
- `08h`
- `2Ch`
- `10h`
- `0Eh`
- `24h`
- `60h`
- `FFh`

Those should be read as continuation and bridge states inside the same lattice, not as separate named openings.

## Threaded Early-Search Records

Once the front-end accepts or redirects an early move, it seeds the overlapping threaded records at `30ADh-30B7h`.

Those records carry:

- Tagged `FROM/TO` squares
- A descriptor/result byte
- A continuation byte

The continuation byte is especially important because it threads control flow through the early-game path. Some continuation values route immediately back to generic search, while others keep the move inside the special early threaded path.

This is why the firmware's opening behaviour is better described as a compact control system than as a flat stored book of named lines.

## Level-Dependent Opening Families

The level loader in `level_setup_banner_and_params` does more than configure search windows. It also influences the early opening style.

The current project mapping is:

| Levels | Main `1.e4` family |
| --- | --- |
| `1 / 3 / 4 / 7` | Sicilian family |
| `2 / 5 / 6` | `...e5` family, including Ruy Lopez and Italian continuations |

The early selector is not determined by level alone. Startup timing also participates, which is why the French family appears as a genuine early branch even though it is not the default `1.e4` reply cluster for every startup state.

## `CB` Computer-First Path

`CB` is not only a side/orientation key.

Before the first committed move:

- On levels `1-4`, it acts as "computer plays first"
- The internal board is seeded so the opening begins with `d2-d4`
- The follow-up lattice states then route the early game through the White-side queen-pawn families

On levels `5-7`, the same key does not follow the same automatic opening preload path.

This matters because some opening families are most clearly exposed through the computer-first route rather than through human-first play.

## Documented Opening Families

The current project mapping ties the following named families to the firmware.

### Sicilian Defense

Representative line:

`1. e4 c5 2. Nf3 d6 3. d4 cxd4`

This family is the main `1.e4` path for levels `1/3/4/7`.

### French Defense

Representative lines:

- `1. e4 e6 2. d4 d5 3. Nc3 Nf6`
- `1. e4 e6 2. d4 d5 3. e5 c5`

This family is part of the early selector, but it is not the only `1.e4` branch. It shares the opening system with the level/timing dependent selector rather than appearing as a permanently fixed reply.

### Ruy Lopez

Representative line:

`1. e4 e5 2. Nf3 Nc6 3. Bb5 a6`

This sits inside the `...e5` family used by levels `2/5/6`.

### Italian Game

Representative line:

`1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5`

This is another continuation inside the same `...e5` family.

### Slav Defense

Representative lines:

- As Black: `1. d4 d5 2. c4 c6`
- As White in the `CB` path: `1. d4 d5 2. c4 c6 3. Nf3`

The important point is that the firmware clearly supports Slav structure from both sides of the board.

### Queen's Gambit Declined

Representative line:

`1. d4 d5 2. c4 e6 3. Nc3`

This is exposed most clearly through the `CB` computer-first route on levels `1-4`.

### Four Knights Transposition

A direct pure Four Knights move order is not yet the main documented path.

What the project has mapped is the closely related transposed setup:

`1. e4 e5 2. Nf3 Nc6 3. Nc3 Bc5 4. Bc4 Nf6`

This reaches a Four Knights Italian-style structure by transposition rather than by the most direct move order.

## Opening Families by Entry Mode

The following summary is useful when reading the firmware:

| Entry mode | Main documented families |
| --- | --- |
| Human-first `1.e4` | Sicilian, French, `...e5` family with Ruy/Italian continuations |
| Human-first `1.d4` | Slav family |
| `CB` computer-first on levels `1-4` | queen-pawn openings as White, including QGD and Slav continuations |

This is a better match to the ROM than a single "book openings" list, because the same family can be reached through different lattice states and handoff records.

## Coverage and Limits

The current project mapping should be read as a documented set of identified families, not as a proof that every possible early branch has already been exhausted.

The present boundary is:

- Sicilian, French, Ruy Lopez, Italian, Slav, and Queen's Gambit Declined are mapped
- The Four Knights is mapped through a transposed Italian-style setup
- The selector depends on both level and startup timing
- Quiet first-move families and some deeper continuation trees are not yet claimed exhaustive

So the correct claim today is:

- The firmware definitely contains multiple distinct early families
- Those families are integrated into the front-end lattice and threaded search handoff
- The project has already mapped several concrete named openings
- The opening system should not yet be treated as globally complete

## Summary

The opening system of Chess Challenger 7 Rev. B is not a separate flat repertoire table. It is a compact early-game control layer built from:

- The page-`02` front-end state lattice
- The progress counter at `3081h`
- Overlapping threaded move records in page `30h`
- Compact page-`01` microcode and continuation tags

That design explains both its strength and its density:

- It can steer the game into recognisable opening families
- It reuses the same engine machinery as later play
- It stores early-game knowledge as control structure rather than as a simple list of named lines
