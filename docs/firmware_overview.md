# Firmware Overview

## Purpose

This document is the recommended first reading for the project.

Its job is to explain the firmware at a structural level before the reader dives into narrower topics such as the front-end state machine, move generation, evaluation, or the early opening system.

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

## Scope

This overview answers four questions:

1. What kind of program is stored in the ROM?
2. What happens from power-on to the normal idle loop?
3. Which major subsystems make the machine work?
4. How do those subsystems connect to each other during a normal move cycle?

It does not try to replace the detailed documents that should later cover:

- Hardware and memory layout
- Front-end and command flow
- Move generation and search
- Evaluation
- Opening behaviour

## Firmware In One Page

At a high level, the ROM is organized as a compact real-time control program with four tightly coupled responsibilities:

- Initialize the board, UI state, and level-dependent search parameters
- Multiplex the display and keypad through the same I/O path
- Accept commands and human move entry through a front-end state lattice
- Generate, evaluate, and publish the machine's response move

The firmware is not split into a clean "UI program" and a separate "chess engine binary". Instead, the front-end, the move generator, the evaluator, and the early-game control logic share RAM structures and hand control back and forth through compact helper routines.

That shared design is one of the defining characteristics of this ROM:

- The front-end stores move and state information directly in page `30h`
- The engine reads and writes the same page `30h` structures
- Several compact ROM tables are both data and control descriptors, depending on the path that reaches them

## Main Execution Flow

### 1. Cold Start

Boot begins in `cold_start` in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

This routine:

- Waits until no key is currently held
- Builds the live `0x88` board from `tbl_initial_board_hi_nibbles`
- Clears front-end/UI state
- Seeds the initial key/front-end state
- Loads the initial level banner into the display buffer
- Enters the main polling loop

The important architectural point is that the board is not stored as a flat 64-byte board. The live board uses a `0x88` layout, which makes directional stepping and off-board detection cheap during search.

### 2. Main Polling Loop

Normal idle execution lives in `main_scan_loop` and `scan_mux_digit_and_keypad_slice` in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

This loop repeatedly:

- Selects one display/keypad slice
- Reads keypad rows through the same multiplexed port path
- Debounces the current candidate key pattern
- Refreshes the four visible digits plus LED-related latch outputs

This means the machine is fundamentally time-sliced. There is no background interrupt-driven UI. The display, the keypad, and several visible status effects all depend on repeated execution of the polling loop.

### 3. Front-End Command and Move Entry

Once a key is stable, control passes to `handle_debounced_key` in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

That path handles:

- Mode keys such as `CB`, `CL`, `LV`, `PV`, `EN`, `DM`, and `PB`
- Board review and board-edit behaviour
- Normal move entry
- The transition from human input to engine response

Normal square entry is a two-keystroke square builder:

- First key selects the file nibble
- Second key selects the rank nibble

Those square bytes are written directly into the move window in page `30h`, then rendered back to the display through `rebuild_from_to_display`.

### 4. Engine Handoff

Once the visible move pair is accepted, control flows into `start_engine_move_or_search` and then `search_driver` in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

This is the real bridge between front-end and engine.

At this point the firmware:

- Commits or replays the move on the live board
- Seeds compact move-record state in page `30h`
- Loads the current level-dependent search window descriptor
- Chooses between staged search, threaded early-game paths, and script-driven piece traversal

The important design choice here is that the engine does not consume a large abstract position object. It consumes a compact shared workspace assembled by the front-end and normalized just before search begins.

### 5. Move Generation and Candidate Flow

Search then proceeds through a combination of:

- Staged move-record windows in page `30h`
- Piece-family script dispatch from `search_branch_when_piece_present`
- Compact executable script logic driven by `vector_script_interpreter`
- Candidate comparison and publication logic

The firmware uses several dense ROM tables and script fragments instead of large explicit procedural code blocks. That keeps the ROM small, but it also means the design is table-heavy and control-flow-heavy at the same time.

### 6. Evaluation and Move Publication

Once candidate moves are materialized, the engine runs two major scoring layers:

- A sidecar-driven pre-evaluation sweep
- A full board evaluation sweep

These live around `normalize_window_and_board_pointer`, `sidecar_pre_eval_square_loop`, and `board_evaluation_sweep` in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

The final selected move is then:

- Stored back into the visible move window
- Reflected into the display-oriented move bytes
- Used to update LEDs and post-search status
- Returned to the polling loop through `post_search_status_update`

## Major Subsystems

### Board Representation

The live board uses a `0x88` layout in RAM.

That choice matters because it simplifies:

- Directional stepping
- Off-board tests
- Square iteration
- Compact script execution for piece movement

The ROM also maintains a parallel "sidecar" interpretation of the `0x88` holes. Those bytes track control counts and least-valuable-attacker classes and are later consumed by the evaluator.

### Front-End State Lattice

The front-end is not driven by a simple chain of conditionals. It relies on the page-`02` transition table rooted at `tbl_frontend_state_phase_pairs` in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

That table combines:

- A low-byte front-end/key state
- A phase stride derived from game progress
- Tagged `DE` pairs that describe expected visible moves and the next transition family

This is one of the central structures of the firmware, because it links the visible move-entry UX to early-game behaviour and to the engine handoff.

### Level and Search Scheduling

Search depth and candidate window layout are controlled by compact level descriptors in `tbl_level_setup` and by the stage-window decoder routines in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

These descriptors do not simply mean "depth 1, 2, 3...". They define:

- Which staged record windows exist
- How many records each window can hold
- Which route bits are active
- Which stages participate at each level

### Threaded Move Records

The engine uses compact threaded records in page `30h` as handoff and candidate structures.

These records are important because they connect:

- Accepted visible moves
- Early-game control flow
- Candidate replay
- Staged search windows

They are one of the reasons the firmware feels dense: the same bytes can act as move bytes, continuation tags, staging metadata, or evaluation inputs depending on the active path.

### Piece Scripts and Microcode

The ROM does not encode all movement logic as large hand-written routines per piece. Instead, a substantial part of move traversal is driven by compact executable script bytes and tiny postprocess helpers.

Key routines here are:

- `search_branch_when_piece_present`
- `vector_script_postprocess`
- `vector_script_interpreter`
- `test_square_from_script_delta`

This is why the disassembly contains regions that are best understood as executable microcode rather than passive tables.

### Evaluation

The evaluation pipeline has two distinct layers.

First, the sidecar pre-evaluation compresses local control and exchange conditions into coarse tactical information.

Second, the board sweep adds:

- Piece-square style effects
- Early-phase biases
- King-edge and neighborhood pressure
- Repeated-move penalties
- Material-related adjustment

The compact dispatch table rooted at `tbl_sidecar_eval_dispatch_root` is one of the key ROM structures for this stage.

### Early-Game / Opening Control

The ROM clearly distinguishes early-game behaviour from later generic search, but it does so through compact control structures rather than through a simple flat list of named opening moves.

In practical terms, the early-game system sits at the boundary between:

- The front-end state lattice
- Threaded move records
- Compact script/continuation bytes
- The normal search and evaluation machinery

That is why the opening system should be documented separately from the general search pipeline, even though both ultimately reuse the same underlying engine machinery.

## What To Read Next

After this overview, the most natural reading order is:

1. hardware and memory layout
2. front-end and command flow
3. move generation and staged search
4. evaluation
5. opening behaviour

If a reader wants to navigate directly in the code, the most useful starting symbols are:

- `cold_start`
- `main_scan_loop`
- `handle_debounced_key`
- `start_engine_move_or_search`
- `search_driver`
- `search_branch_when_piece_present`
- `vector_script_interpreter`
- `normalize_window_and_board_pointer`
- `sidecar_pre_eval_square_loop`
- `board_evaluation_sweep`
- `post_search_status_update`

## Summary

The Chess Challenger 7 Rev. B firmware is best understood as a compact, table-driven control program that merges UI, move entry, early-game control, search, and evaluation into one shared RAM-and-ROM workflow.

If the reader keeps that idea in mind, the disassembly becomes much easier to follow:

- The polling loop owns time
- Page `30h` owns shared working state
- Compact tables and scriptlets own much of the control flow
- The engine and front-end are deeply intertwined rather than cleanly separated
