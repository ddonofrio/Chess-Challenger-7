# Reference Tables

## Purpose

This document is a quick technical appendix.

It summarizes the most useful constants, tables, and labels so that a reader can navigate the firmware without scanning the whole disassembly every time.

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

## Scope

This appendix collects:

- Raw key codes
- Visible messages
- Important RAM labels
- Important ROM tables
- Opening-family root offsets
- Level setup bytes

For explanation and flow, use the main topic documents in `docs/`.

## Raw Key Codes

The firmware uses these debounced raw front-panel codes:

| Key | Value |
| --- | --- |
| `EN` | `EEh` |
| `PV` | `EDh` |
| `D4` | `EBh` |
| `H8` | `E7h` |
| `CL` | `DEh` |
| `PB` | `DDh` |
| `C3` | `DBh` |
| `G7` | `D7h` |
| `CB` | `BEh` |
| `DM` | `BDh` |
| `B2` | `BBh` |
| `F6` | `B7h` |
| `RE` | `7Eh` |
| `LV` | `7Dh` |
| `A1` | `7Bh` |
| `E5` | `77h` |

The diagonal board keys `A1..H8` have two roles:

- Square-entry selectors in normal move entry
- Piece-palette selectors in board-edit mode

## Display Messages

The page-zero message bytes used directly by the front-end include:

| Symbol | Bytes | Visible text |
| --- | --- | --- |
| `msg_level_prefix` | `39h 38h 00h 06h` | `CL 1` |
| `msg_double` | `5Eh 5Ch 1Ch 7Ch` | `doub` |
| `msg_problem` | `73h 50h 5Ch 7Ch` | `Prob` |

These are stored as NE591/7-segment glyph bytes, not as ASCII.

## Piece Coding

The live `0x88` board uses this signed piece format:

| Value | Meaning |
| --- | --- |
| `00h` | empty |
| `01h` | pawn |
| `02h` | knight |
| `03h` | bishop |
| `04h` | rook |
| `05h` | queen |
| `06h` | king |

Negative values represent the opposite side.

### Signed Board Codes

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

### Material Lookup Values

The signed board code is not the same thing as the evaluator's material weight.

The lookup table rooted at `tbl_piece_property` maps piece identity to these material values:

| Piece | Material value |
| --- | --- |
| pawn | `1` |
| knight | `3` |
| bishop | `3` |
| rook | `5` |
| queen | `9` |
| king | `9` |

## Sidecar Byte Format

Each sidecar byte packs four tactical fields:

| Bits | Meaning |
| --- | --- |
| `7-6` | positive-side control count |
| `5-4` | negative-side control count |
| `3-2` | positive-side least-valuable-attacker class |
| `1-0` | negative-side least-valuable-attacker class |

## Important RAM Labels

### Board and Front-End State

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_board_0x88` | `3000h` | live `0x88` board |
| `ram_level` | `3080h` | selected level |
| `ram_phase_turn_counter` | `3081h` | game-progress counter |
| `ram_frontend_flags0` | `3082h` | front-end/setup flags |
| `ram_frontend_flags1` | `3083h` | mode/display flags |
| `ram_board_cursor_or_material` | `3084h` | UI cursor or material accumulator |
| `ram_led_select_bits` | `3085h` | `CHECK` / `I LOSE` bits |
| `ram_move_to_square` | `3086h` | visible `TO` square |
| `ram_move_from_square` | `3087h` | visible `FROM` square |
| `ram_disp_from_lo`..`ram_disp_to_hi` | `3088h-308Bh` | display buffer or score words |
| `ram_key_state` | `308Ch` | front-end lattice offset |

### Search Scheduling

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_schedule_base_offset` | `308Eh` | base offset into stage descriptor pairs |
| `ram_schedule_stage_mask` | `308Fh` | active-stage mask |
| `ram_stage_route_mask` | `3090h` | alternate-route mask |
| `ram_search_stage_cursor` | `3091h` | live rotating stage bit |

### Best-Move Publication

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_best_move_from_tagged` | `3092h` | tagged best `FROM` |
| `ram_best_move_to_tagged` | `3093h` | tagged best `TO` |
| `ram_prev_move_to_square` | `3094h` | previous destination square |

### Threaded Early-Search Records

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_root_record_base` | `30ADh` | lower/root record base |
| `ram_root_from_tagged` | `30AEh` | root tagged `FROM` |
| `ram_root_to_tagged` | `30AFh` | root tagged `TO` |
| `ram_reply_record_descriptor` | `30B2h` | shared lower `+5` / upper `+0` byte |
| `ram_reply_from_tagged` | `30B3h` | reply tagged `FROM` |
| `ram_reply_to_tagged` | `30B4h` | reply tagged `TO` |
| `ram_reply_continuation_tag` | `30B7h` | reply continuation byte |

### Search Pool and Script Slots

| Symbol | Address | Purpose |
| --- | --- | --- |
| `ram_search_window_guard_lo` | `30B8h` | guard/header band |
| `ram_search_record_pool_base` | `30BBh` | staged 4-byte record pool |
| `ram_search_record_pool_top` | `30E3h` | sentinel above widest pool |
| `ram_blink_or_random0` | `30E4h` | blink/status helper |
| `ram_blink_or_random1` | `30E5h` | blink phase / random source |
| `ram_script_slots` | `30E6h` | four compact script slots |

## Important ROM Tables

| Symbol | Purpose |
| --- | --- |
| `tbl_seg_digits_hex_like` | segment glyphs, message bytes, helper bytes |
| `tbl_piece_property` | signed material lookup and piece-script dispatch bytes |
| `tbl_frontend_state_phase_pairs` | page-`02` front-end state lattice |
| `tbl_display_rank_glyphs` | rank display lookup used by `rebuild_from_to_display` |
| `tbl_display_file_glyphs` | file display lookup used by `rebuild_from_to_display` |
| `tbl_initial_board_hi_nibbles` | initial board template plus opening square classes |
| `tbl_level_setup` | compact per-level stage schedule |
| `tbl_sidecar_eval_dispatch_root` | root control/exchange evaluator dispatch |
| `tbl_sidecar_eval_equal_control` | equal-control evaluator family |
| `tbl_sidecar_eval_negative_control_dominant` | negative-side-control-dominant family |
| `tbl_sidecar_eval_positive_control_dominant` | positive-side-control-dominant family |
| `tbl_king_edge_distance` | king square-distance / edge table |

## Opening-Family Root Offsets

These `ram_key_state` roots are especially useful when reading the early-game lattice:

| Offset | Meaning |
| --- | --- |
| `FCh` | White king-pawn family |
| `54h` | White queen-pawn family |
| `FEh` | Black `...e5` family |
| `3Eh` | Sicilian family |
| `1Eh` | French family |
| `56h` | `...d5 / ...e6` development family |

Important follow-up and bridge offsets include:

| Offset | Role |
| --- | --- |
| `38h`, `F8h`, `1Ah`, `18h`, `08h` | follow-up / phase-shifted continuations |
| `2Ch`, `10h`, `0Eh`, `24h`, `60h`, `FFh` | bridge / handoff offsets |

## Level Setup Bytes

The compact level setup table expands into these live schedule bytes:

| Level | Bytes |
| --- | --- |
| `1` | `8C 02 04 8C` |
| `2` | `8C 06 08 00` |
| `3` | `00 00 08 8C` |
| `4` | `8C 10 20 8C` |
| `5` | `8C 06 10 8C` |
| `6` | `8C 0E 10 BB` |
| `7` | `BB 0A BB 05` |

Those bytes are then interpreted as:

- Base offset into the page-`0C` descriptor pairs
- Active-stage mask
- Alternate-route mask
- Initial window/header byte

## Important Script Entries

The main page-`01` move-generation families are:

| Entry | Family |
| --- | --- |
| `0100h` | pawn / first-rank special microcode |
| `0176h` | knight |
| `0190h` | king |
| `01AAh` | rook / queen orthogonal |
| `01C6h` | bishop / queen diagonal |

## Quick Reading Landmarks

If you want to jump into the disassembly quickly, these are the most useful landmarks:

| Symbol | Role |
| --- | --- |
| `cold_start` | boot and initial board build |
| `main_scan_loop` | display/keypad polling |
| `handle_debounced_key` | front-end command dispatch |
| `start_engine_move_or_search` | front-end to engine bridge |
| `search_driver` | main search dispatcher |
| `search_branch_when_piece_present` | per-piece move-generation branch |
| `vector_script_interpreter` | compact script executor |
| `sidecar_pre_eval_square_loop` | coarse tactical pre-evaluation |
| `board_evaluation_sweep` | full board scoring |
| `post_search_status_update` | final move publication/update |

## Summary

This appendix is meant to reduce lookup time while reading the code.

The most useful way to use it is:

1. read the main topic document
2. keep this file open as a quick address and symbol reference
3. jump back into the main disassembly when needed
