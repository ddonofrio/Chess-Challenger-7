# Front-End and Game Flow

## Purpose

This document explains how the firmware handles:

- Power-on initialization
- The polling loop
- Keypad debounce
- Move entry
- Front-panel commands
- Board review, board edit, and problem mode

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

For the machine model behind this flow, see [`./hardware_and_memory_map.md`](./hardware_and_memory_map.md).

## Scope

This file follows the user-visible front-end.

It stops at the point where control is handed to the engine. The staged search, piece scripts, and evaluation pipeline are covered elsewhere.

## Cold Start

Boot begins in `cold_start`.

The startup sequence is compact but very structured:

1. wait until no key is currently held
2. copy the initial board template into the live `0x88` board
3. clear front-end state
4. seed the initial visible move window
5. load the current level banner
6. enter the polling loop

Two details are worth calling out.

First, the board is not copied from a plain piece list. The firmware uses `tbl_initial_board_hi_nibbles`, whose high nibble becomes the signed piece code while the low nibble survives as an opening/development square class.

Second, the machine is immediately ready for both UI and engine work because the same RAM page is shared by both.

## Main Polling Loop

Normal idle execution lives in `main_scan_loop` and `scan_mux_digit_and_keypad_slice`.

The loop has one basic responsibility: keep the machine alive by cycling through one scan slice at a time.

Each slice does four things:

1. select one digit/keypad column
2. sample keypad rows
3. update debounce state
4. refresh one display digit plus the LED bits

There is no background UI thread and no interrupt-driven display refresh. The firmware keeps the panel working by returning to this loop over and over.

## Debounce

Debounce state is kept in the temporary `D/E` pair used by the poller.

The logic is simple but effective:

- A new key pattern is stored in `D`
- `E` counts how long the same pattern has persisted
- A noisy or multi-row pattern saturates to a special value
- An idle slice decays the stale pattern until it fully expires

Once the same stable pattern has been seen enough times, control passes to `handle_debounced_key`.

This is why command handling and move entry always begin from the same place: the front-end only trusts a key after the polling loop has stabilized it.

## Visible Move Window

The visible move window is stored as:

- `ram_move_to_square` at `3086h`
- `ram_move_from_square` at `3087h`

The rendering order is the reverse of the storage order:

- The high byte is rendered first
- The low byte is rendered second

So the left display window is visually the `FROM` square even though the lower address contains the `TO` square.

The routine `rebuild_from_to_display` converts those two `0x88` bytes into four display glyphs.

## Normal Square Entry

Normal square entry is a two-keystroke state machine.

Each square is built in two steps:

1. file selector
2. rank selector

The eight diagonal board keys `A1..H8` are reused for both jobs. Internally, the builder works like this:

- First key turns `FFh` into `F0h..F7h`
- Second key turns `Fxh` into `00h..77h`

That is exactly the `0x88` board representation.

One example makes the encoding clear:

- `E5, B2` builds `e2`
- `E5, D4` builds `e4`
- `E5, B2, E5, D4, EN` therefore means `e2-e4`

The firmware fills `FROM` first and then `TO`. Once both bytes are valid, extra square keys are ignored until the move is accepted or cleared.

## Command Keys

The front-end command handler recognizes these raw command keys:

- `RE`
- `CB`
- `CL`
- `LV`
- `PV`
- `EN`
- `DM`
- `PB`

### `RE`

`RE` is a hard reset path.

The handler clears the segment output and then uses `RST 00h`, returning execution to the reset entry.

### `CL`

`CL` is the clear key.

Depending on current mode, it can:

- Clear selection state
- Clear board-review state
- Clear an edited square
- Reset the visible move window back to `FF/FF`

It always returns through the shared UI reset path, so the display is rebuilt immediately after the clear action.

### `LV`

`LV` increments the current level, wraps after level `7`, and refreshes the rightmost display digit inside the `CL n` banner.

The level number is stored in `ram_level`, but the level key does more than just alter a visible number. It also changes the staged search schedule and the early opening-family selector loaded later by `level_setup_banner_and_params`.

### `PV`

`PV` enters position verification, which doubles as board review.

In this mode:

- `ram_board_cursor_or_material` is treated as a `0x88` cursor
- The cursor walks the board while skipping the file-8 holes
- The selected square and piece class are rendered into the visible move window

`PV` is therefore not an engine feature. It is a front-end board-inspection mode built directly on top of the live board array.

### `EN`

`EN` accepts the current state.

Depending on context, it can:

- Toggle the sign of the currently reviewed square in edit/problem flows
- Accept a move pair
- Arm or complete a double-move sequence
- Force an engine handoff
- Accept one step in the early front-end state lattice

This is one of the reasons the front-end feels dense: `EN` is a mode-sensitive commit key, not a single-purpose "submit move" action.

### `DM`

`DM` arms the double-move mode and displays the `doub` banner.

The associated mode bit is then checked by `EN` when a full move pair is present.

### `PB`

`PB` enters problem mode.

This path:

- Switches the mode flags
- Forces `ram_key_state` to `FFh`
- Clears the board workspace if needed
- Displays `Prob`
- Routes the machine into the engine/problem entry path

Problem mode therefore uses the same front-end infrastructure as ordinary play, but starts from a different mode/board state.

### `CB`

`CB` has two distinct roles.

In ordinary play it toggles side/orientation bookkeeping.

Before the first committed move, however, it activates the computer-first startup path. On levels `1-4`, that path seeds the machine so that the opening begins with `d2-d4` already applied and displayed. On levels `5-7`, the same key falls back to the simpler side/orientation path.

## Front-End State Lattice

The move-entry UX is not driven by a flat chain of special cases. It is controlled by the page-`02` transition lattice rooted at `tbl_frontend_state_phase_pairs`.

Three inputs cooperate here:

- `ram_key_state`
- The phase stride derived from `ram_phase_turn_counter`
- A tagged `DE` transition pair fetched from the table

Those tagged `DE` pairs can:

- Describe a literal visible `FROM/TO` pair
- Accept the current visible pair without literal comparison
- Request a retry-family advance
- Force `ram_key_state` back to `FFh`
- Request the `CHECK` LED on acceptance

This is why the early game is tightly coupled to the front-end: the same table that validates visible move entry also steers the firmware toward specific early-game families.

## Accepting a Move

When `EN` is pressed with a full move pair visible, the firmware takes one of two broad paths.

### Front-End Acceptance Path

If the current lattice state expects that visible move, the firmware:

1. fetches the follow-up state pair
2. normalizes `ram_key_state`
3. increments `ram_phase_turn_counter`
4. optionally raises `CHECK`
5. applies the visible move on the live board
6. hands control to the engine path

### Immediate Threaded Handoff Path

If the visible move does not match the current expected pair and the transition descriptor does not allow a retry-family advance, the firmware seeds the lower threaded record and drops straight into the search setup.

In other words, the front-end can either guide the move through the state lattice or bypass it into the generic engine path.

## Board Review and Board Edit

The diagonal square keys are reused again in board-edit mode.

When the edit palette is active, those keys no longer build squares. Instead, they select piece classes:

| Key | Piece |
| --- | --- |
| `B2` | pawn |
| `D4` | knight |
| `F6` | bishop |
| `H8` | rook |
| `A1` | queen |
| `C3` | king |

The sign of the stored piece is inferred from the previous square contents, so the same palette can produce both sides.

This is a good example of the firmware's general style: the same physical keys are repurposed by mode rather than given separate handlers or tables for every front-panel feature.

## Modes of Operation

From the front-end's point of view, the machine has several overlapping operating modes:

- Normal move-entry mode
- Board review / position verification mode
- Board edit mode
- Double-move mode
- Problem mode
- Computer-first startup mode via `CB`

These are not implemented as a clean enum. They are encoded through the flag bytes at `3082h` and `3083h`, the current `ram_key_state`, and the live contents of the visible move window.

That shared-state design keeps the ROM small, but it also means the front-end is best understood as a state lattice rather than as a tree of independent commands.

## Summary

The front-end of Chess Challenger 7 Rev. B is a real-time polling system that merges:

- Keypad scanning
- Display multiplexing
- Command dispatch
- Board review/edit
- Move entry
- Early-game steering

The important mental model is this:

- The polling loop owns timing
- The visible move window owns the user-facing selection
- `ram_key_state` plus the page-`02` lattice own front-end progression
- `EN` is the commit point that bridges UI state into engine state
