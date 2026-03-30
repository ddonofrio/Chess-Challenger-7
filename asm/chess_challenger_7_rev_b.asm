; Chess Challenger 7 Rev. B
; Z80 disassembly of the game board ROM
; Disassembly of the Chess Challenger 7 Rev. B board by Diego D'Onofrio
;
; Documented Firmware Structure and Behaviour:
; - 0000h-0FFFh ROM, 3000h-3077h 0x88 board, 3088h-308Bh display/search words
; - keypad/display mux, CHECK/I LOSE LEDs, buzzer write path
; - front-panel command keys and their raw codes
; - board-square entry encoded through the eight diagonal keys: each square is built as file first, then rank
; - core reset / polling / key-dispatch flow
; - 3081h and the 23h/26h cutoffs as the main early-phase / patterned-opening gates
; - 308Eh-3091h as a compressed search-stage selector and nested page-30 move-record-window schedule
; - 3087h = FROM and 3086h = TO in the displayed move pair
; - 3092h/3093h as tagged best-move bytes, and 3094h as the previous TO square
; - 0176h..01DFh and 0EEEh as compact move/attack script machinery
; - 30ADh-30B7h as two overlapping 6-byte threaded root/reply move records feeding the early search
; - 30B8h-30E3h as the shared search workspace: a guard/header band plus nested 4-byte move-record pools
; - early opening play encoded as compact ROM microcode/phase descriptors plus threaded page-30 handoff records,
;   not as a flat ROM table of named FROM/TO opening lines
; - startup timing and level selection both participate in the early opening-family selector
; - levels 1/3/4/7 route 1.e4 into a Sicilian family, while 2/5/6 route it into the ...e5 family and support Ruy/Italian continuations
; - additional startup timings also route 1.e4 into a French family
; - CB before the first committed move acts as "computer plays first" on levels 1-4 and preloads/applies d2-d4
; - level 2 reaches a transposed Four Knights Italian setup via
;   1.e4 e5 2.Nf3 Nc6 3.Nc3 Bc5 4.Bc4 Nf6
; - documented early lines include 1.e4 c5 2.Nf3 d6 and 1.d4 d5 2.c4 c6
; - the sidecar byte in each 0x88 hole as a packed control/exchange descriptor:
;   bits7-6 = positive-side control count, bits5-4 = negative-side control count,
;   bits3-2 = positive-side least-valuable-attacker class, bits1-0 = negative-side least-valuable-attacker class
; - 0F72h onward as the compact evaluation/exchange prelude, root-dispatch, and nibble-pair outcome tables driven by that sidecar descriptor
; - 0FC0h-0FFFh as the king-distance table, with part of the same ROM tail also reused as terminal dispatch data

        org 0000h

; --- RAM symbols ---------------------------------------------------------
ram_board_0x88               equ 3000h ; 8x8 board stored on a 0x88 grid (only 3000h-3077h are meaningful)
ram_level                    equ 3080h ; front-panel level selected by the LV key
ram_phase_turn_counter       equ 3081h ; monotonic board-action / game-progress counter; starts at 1 and advances on committed board transitions
ram_frontend_flags0          equ 3082h ; mixed front-end/setup flag byte
ram_frontend_flags1          equ 3083h ; front-end mode/display flag byte
ram_board_cursor_or_material equ 3084h ; overloaded: board-review / edit cursor in the front-end, signed material accumulator during engine search
ram_led_select_bits          equ 3085h ; CHECK/I LOSE bits merged into the multiplex byte
ram_move_to_square           equ 3086h ; display-pair low byte: code flow and rendering order show that this is the TO square
ram_move_from_square         equ 3087h ; display-pair high byte: code flow and rendering order show that this is the FROM square
ram_disp_from_lo             equ 3088h ; overloaded: display bytes in UI, low 16-bit search/eval word during engine search
ram_disp_from_hi             equ 3089h ; overloaded: display/search scratch
ram_disp_to_lo               equ 308Ah ; overloaded: display bytes in UI, high/second 16-bit search window word during engine search
ram_disp_to_hi               equ 308Bh ; overloaded: display/search scratch
ram_key_state                equ 308Ch ; debounced key/front-end decode-state code; effectively the low-byte offset into the page-02 state/phase DE-pair lattice
ram_piece_or_square_tmp      equ 308Dh ; current piece code / current square script temp
ram_schedule_base_offset     equ 308Eh ; base offset into the compact page-0C search-stage parameter-pair table
ram_schedule_stage_mask      equ 308Fh ; one-bit mask of the stages that are active for the current level
ram_stage_route_mask         equ 3090h ; one-bit mask of the stages that take the alternate normalize/resume path in search_driver
ram_search_stage_cursor      equ 3091h ; live rotating one-bit stage cursor; bit0 later gates publication of the visible best-move pair
ram_best_move_from_tagged    equ 3092h ; tagged best-move FROM square copied out of the move-record area; can settle before 3086h/3087h are refreshed for some slower opening replies
ram_best_move_to_tagged      equ 3093h ; tagged best-move TO square copied out of the move-record area; can expose a provisional reply ahead of the visible move window
ram_prev_move_to_square      equ 3094h ; previous move destination square, reused by evaluation
ram_root_record_base         equ 30ADh ; base byte of the lower/root 6-byte threaded move record used during the early-search handoff
ram_root_from_tagged         equ 30AEh ; tagged FROM square in the lower/root threaded record; reused by the re-move penalty
ram_root_to_tagged           equ 30AFh ; tagged TO square in the lower/root threaded record
ram_reply_record_descriptor  equ 30B2h ; overlapping descriptor/continuation byte: lower/root +5 tag, upper/reply +0 byte, and early-phase evaluation descriptor
ram_reply_from_tagged        equ 30B3h ; tagged FROM square in the overlapping upper/reply threaded record
ram_reply_to_tagged          equ 30B4h ; tagged TO square in the overlapping upper/reply threaded record
ram_reply_continuation_tag   equ 30B7h ; +5 continuation / dispatch tag of the upper/reply threaded record
ram_search_window_guard_lo   equ 30B8h ; stage-specific clears always run down to this low-byte guard/header band
ram_search_record_pool_base  equ 30BBh ; shared 4-byte move-record pool used by the staged search windows
ram_search_record_pool_top   equ 30E3h ; one-byte sentinel above the widest 10-record move pool
ram_blink_or_random0         equ 30E4h ; blink/status helper byte toggled by UI/search publication paths
ram_blink_or_random1         equ 30E5h ; free-running scan-loop byte reused as the blink phase and random tie-break source
ram_script_slots             equ 30E6h ; four slots used by the inline vector-script engine

; Threaded 6-byte early-search record layout used by 061Ah / 07FDh / 08EDh / 0AFDh:
;   +0 = descriptor / result byte
;   +1 = tagged FROM square (0x88 square code with tag bits later stripped by AND 77h)
;   +2 = tagged TO square   (0x88 square code with tag bits later stripped by AND 77h)
;   +3/+4 = copied word from ram_disp_to_lo
;   +5 = continuation / dispatch tag = low byte of the threaded caller's return address
;        = values 08h/17h/1Eh/43h/4Dh/5Bh are produced by the embedded RST 38h sites in 0100h-015Ah
;        = values 5Eh/5Fh/60h are the synthetic trampoline tail at 015Eh-0160h and fall back into the generic search branch at 08EDh
; The lower/root record occupies 30ADh-30B2h, and the overlapping upper/reply record occupies 30B2h-30B7h.

; Identified front-end flag bits:
;   3082h bit0 = side/orientation toggle changed by CB once play is already in progress
;   3082h bit1 = problem mode / problem-board semantics active
;   3082h bit2 = double-move continuation pending after the first leg is accepted
;   3082h bit3 = scripted/UI refresh pending latch
;   3082h bit4 = engine-response / command-handover latch; set after committed moves and computer-first preload, cleared by the next manual square-entry refresh
;   3083h bit0 = blinking request for the display path
;   3083h bit1 = live blank-this-refresh latch used by the display mux
;   3083h bit2 = position-verification mode active
;   3083h bit3 = double-move mode armed
;   3083h bit4 = follow-up latch set when the first half of a double move is accepted
;
; Stable ram_key_state root offsets:
;   FCh = initial/default move-entry root offset before the first committed board transition
;   38h = steady in-game move-entry / engine-response-visible root offset after a committed move
;   56h = computer-first preload root offset reached by the initial CB path on levels that auto-play d2-d4
;   FFh = forced command/problem/double-move handoff offset
; The remaining values are transient or phase-shifted offsets within the same page-02 state/phase lattice; they are advanced by advance_key_repeat_state.
; Phase-1..3 families in that lattice:
;   FCh -> e2-e4, g1-f3, f1-c4
;   54h -> d2-d4, c2-c4, b1-c3
;   FEh -> ...e7-e5, ...b8-c6, ...f8-c5
;   3Eh -> ...c7-c5, ...d7-d6, ...c5xd4
;   1Eh -> ...e7-e6, ...d7-d5, ...g8-f6
;   56h -> ...d7-d5, ...e7-e6, ...g8-f6
;   38h/F8h/1Ah/18h/08h = follow-up or phase-shifted aliases of the same opening-development lattice
;   2Ch/10h/0Eh/24h/60h/FFh = bridge / handoff offsets used to exit or re-enter the front-end transition families

; --- Front-panel raw key codes after scan/invert -------------------------
; A1..H8 serve double duty: in normal move entry each square is assembled in two keypresses,
; file first and rank second (for example E5,B2 = e2 and E5,D4 = e4).
KEY_EN     equ EEh
KEY_PV     equ EDh
KEY_D4     equ EBh
KEY_H8     equ E7h
KEY_CL     equ DEh
KEY_PB     equ DDh
KEY_C3     equ DBh
KEY_G7     equ D7h
KEY_CB     equ BEh
KEY_DM     equ BDh
KEY_B2     equ BBh
KEY_F6     equ B7h
KEY_RE     equ 7Eh
KEY_LV     equ 7Dh
KEY_A1     equ 7Bh
KEY_E5     equ 77h

; --- Piece coding used on the 0x88 board --------------------------------
; 00h empty
; +01 pawn, +02 knight, +03 bishop, +04 rook, +05 queen, +06 king
; negative values = same piece type for the opposite side

; -----------------------------------------------------------------------
; Z80 reset entry. IY is anchored at 3080h so small RAM globals can be addressed as (IY+n).
; calls from 0544h
reset_vector:
    di
    ld iy,ram_level
    jp cold_start
; -----------------------------------------------------------------------
; RST 08h: add the signed delta in A to the global material accumulator currently hosted in 3084h.
; Outside the engine, the same byte is reused by the front-end as the board-review / edit cursor.
; calls from 07D3h, 07EFh, 0A68h, 0A8Ah, 0860h
rst08_add_material_delta:
    add a,(iy+4)
    ld (ram_board_cursor_or_material),a
    ret
; -----------------------------------------------------------------------
; unused RST filler byte
rst_pad_0f:
    db 00h

; -----------------------------------------------------------------------
; RST 10h: two's-complement negate DE.
; calls from 088Dh, 0922h, 09ACh, 09AFh, 09D1h, 0B79h, 0D9Ah
rst10_negate_de:
    ld a,d
    cpl
    ld d,a
    ld a,e
    cpl
    ld e,a
    inc de
    ret
; -----------------------------------------------------------------------
; RST 18h: helper used by the engine to test a square reached by a relative delta kept in A.
; calls from 0E01h, 0E04h, 0E09h, 0E0Ch, 0E0Fh, 0E12h, 0E15h, 0E18h
rst18_step_relative_square:
    ld i,a
    add a,c
    ld l,a
    jp step_and_test_0x88_square
; -----------------------------------------------------------------------
; unused RST filler byte
rst_pad_1f:
    db 00h

; -----------------------------------------------------------------------
; RST 20h: multiply A by 16. Used heavily with 0x88 board coordinates.
; calls from 05C4h, 07D7h, 0A7Ah, 0870h, 0D19h
rst20_mul_a_by_16:
    add a,a
    add a,a
    add a,a
    add a,a
    ret
; -----------------------------------------------------------------------
; unused RST filler byte
rst_pad_25:
    db 00h

; -----------------------------------------------------------------------
; RST 28h: extract the upper nibble (A >> 4) after clearing bit 7.
; calls from 0A40h, 0D87h
rst28_extract_high_nibble:
    and 7Fh
; -----------------------------------------------------------------------
; Entry used when bit 7 is already known-clear and only the >>4 nibble extraction is needed.
; calls from 046Dh, 049Eh, 02F8h, 0301h, 0CCFh, 0CF7h, 0D05h, 0D1Eh
rst28_shift_high_nibble_only:
    rrca
    rrca
    rrca
    rrca
    and 0Fh
    ret
; -----------------------------------------------------------------------
; unused RST filler byte
rst_pad_2f:
    db 00h

; -----------------------------------------------------------------------
; RST 30h: compare the game-progress counter at 3081h against 23h. This is the engine's main early-game / patterned-opening threshold test.
; calls from 0549h, 070Dh, 0CDDh, 03F1h, 0E36h, 0E58h, 0DE0h, 0E7Ch
rst30_cmp_phase_23h:
    ld a,(ram_phase_turn_counter)
    cp 23h                                   ; 23h is the main early-phase cutoff used by UI special cases, move handling, and evaluation.
    ret
; -----------------------------------------------------------------------
; unused space between RST handlers
rst_pad_36:
    db 00h, 00h

; -----------------------------------------------------------------------
; RST 38h: vector-scan helper. Adds a delta to L, rejects off-board 0x88 addresses, then inspects the board cell.
; calls from 0EE3h, 0168h, 0171h
rst38_vector_scan:
    ld i,a
    add a,l
    ld l,a
    and 88h
    ret nz
    ld a,(hl)
    bit 5,c
    jp nz,rst38_capture_or_special_case
    add a,d
    xor d
    ret m
    ld a,(ram_search_stage_cursor)
    or a
    jp nz,make_move_and_update_material
    ld a,(ram_move_from_square)
    cp e
    jr nz,return_board_piece_or_zero
    ld a,(ram_move_to_square)
    cp l
    jp z,start_engine_move_or_search
; -----------------------------------------------------------------------
; jumps from 0053h, 0211h, 0AC3h
return_board_piece_or_zero:
    ld a,(hl)
    or a
    ret
; -----------------------------------------------------------------------
; Copy 4 bytes from page 0 (00xxh) into the 4-digit display buffer at 3088h-308Bh.
; calls from 0491h, 0586h, 06E0h
copy4_from_page0_to_display:
    ld de,ram_disp_from_lo
    ld h,0
; -----------------------------------------------------------------------
; Shared 4-byte LDIR tail used by the level/banner setup path.
; calls from 0442h
copy4_bytes_hl_to_de:
    ld bc,4
    ldir
    ret
; -----------------------------------------------------------------------
; Write the 8 bits of A to the NE591 latch one bit at a time via ports 07h..00h.
; calls from 0505h, 0520h, 0541h, 042Dh, 0B14h
write_ne591_pattern:
    push bc
    ld b,a
    ld c,7
; -----------------------------------------------------------------------
; Shift the next outgoing bit into A bit7 before writing the port byte.
; jumps from 007Ah
shift_next_ne591_output_bit:
    sub a
    rlc b
    jr nc,emit_ne591_latch_bit
    set 7,a
; -----------------------------------------------------------------------
; Emit one latch bit to the currently selected NE591 data port.
; jumps from 0071h
emit_ne591_latch_bit:
    out (c),a
    dec c
    ld a,c
    inc a
    jr nz,shift_next_ne591_output_bit
    pop bc
    ret
; -----------------------------------------------------------------------
; Shared search-front-end helper: clear the vector-script slots, then either dispatch the current square/piece
; into the inline script machinery or resume the board scan.
; jumps from 08A5h
search_or_queue_square:
    bit 5,c
    jr z,search_or_queue_done
    ld e,a
    push hl
    ld hl,ram_script_slots
    ld b,5
; -----------------------------------------------------------------------
; Clear the four 6-byte inline-script reservation slots at 30E6h..30F1h.
; jumps from 008Ch
clear_inline_script_slots_loop:
    ld (hl),FFh
    inc l
    djnz clear_inline_script_slots_loop
    pop hl
    ld a,(ram_search_stage_cursor)
    sub 2
    jp m,search_or_queue_done
; -----------------------------------------------------------------------
; Probe the current 0x88 square in E and decide whether it dispatches to a page-01 script or a plain scan step.
; jumps from 00A7h, 00ABh
dispatch_square_to_inline_script_or_scan:
    ld l,e
    ld a,(hl)
    ld (ram_piece_or_square_tmp),a
    add a,5
    cp 0Bh
    jp nc,run_inline_vector_script
; -----------------------------------------------------------------------
; Advance E to the next legal 0x88 square while skipping the file-8 holes.
; jumps from 0EEBh
advance_to_next_0x88_square_in_e:
    inc e
    ld a,e
    and 8
    jr z,dispatch_square_to_inline_script_or_scan
    add a,e
    ld e,a
    jp p,dispatch_square_to_inline_script_or_scan
; -----------------------------------------------------------------------
; jumps from 0080h, 0094h
search_or_queue_done:
    sub a
    jp scan_board_for_candidate_piece
; -----------------------------------------------------------------------
; page-zero tables: 7-seg glyphs, messages, signed material lookup, and piece-class dispatch helpers
tbl_seg_digits_hex_like:
    ; 7-seg glyphs for digits and auxiliary letters.
    db 3Fh, 06h, 5Bh, 4Fh, 66h, 6Dh, 7Dh, 07h, 7Fh, 3Fh, 77h, 7Ch, 39h, 5Eh, 79h, 71h    ; hex-like 7-seg glyphs
    db 6Fh, 76h, 00h, E7h, D7h, B7h, 77h, EBh, DBh, BBh, 7Bh, FFh, FFh, FEh, FDh, FDh    ; extra glyphs/messages
    ; 00D3h-00D9h are used while updating the sidecar low nibble:
    ; they convert a piece code into the 2-bit least-valuable-attacker class ordering
    ; (queen/king=0, rook=1, minor=2, pawn=3) through the compact add/xor merge at 021Dh-0246h.
    db FCh, 00h, F3h, F7h, F7h, FBh, FFh, FFh, F7h, F7h, FBh, FDh, FDh, FFh    ; piece / state helper table
tbl_piece_property:
    ; 00DAh-00E6h form the signed material lookup indexed by piece code + E0h: -9,-9,-5,-3,-3,-1,0,+1,+3,+3,+5,+9,+9.
    ; 00E7h-00F3h form the per-piece class/dispatch table indexed by piece code + EDh.
    ; The non-pawn values are the low-byte entry points of the executable page-01 piece scripts:
    ;   knight = 76h -> 0176h, king = 90h -> 0190h, rook/queen = AAh -> 01AAh, bishop = C6h -> 01C6h.
    ; pawn = 00h selects the special page-01 path rooted at 0100h.
    db 00h, 01h, 03h, 03h, 05h, 09h, 09h, 90h, AAh, AAh, C6h, 76h, 00h, FFh, 00h, 76h, C6h, AAh, AAh, 90h    ; compact signed material + piece-class helper bytes
msg_level_prefix:
    db 39h, 38h, 00h, 06h    ; "CL 1"
msg_double:
    db 5Eh, 5Ch, 1Ch, 7Ch    ; "doub"
msg_problem:
    db 73h, 50h, 5Ch, 7Ch    ; "Prob"
; 0100h-015Ah are not a plain opening-move table.
; This block forms the special page-01 pawn / first-rank-case move-generator microcode, mixed with threaded decision bytes:
; the FF bytes at 0107h/0116h/011Dh/0142h/014Ch/015Ah are executable RST 38h sites whose return lows
; (08h/17h/1Eh/43h/4Dh/5Bh) become the +5 continuation tags of threaded move records,
; and the late bytes touch 308Dh and the threaded-record state directly.
; In other words, 0100h-015Ah belong to move-generation / threaded search control, not to a flat stored opening repertoire.
; This block contains four compact phases:
;   0100h-010Eh = dispatch on the selector nibble loaded from (HL); if bit5(C) is already set,
;                 emit the 08h delta and jump straight into the 5Bh tail site at 015Ah
;   010Fh-011Dh = two zero-compare gates against adjacent bytes of the selected row, emitting 17h and 1Eh on mismatch
;   011Eh-0142h = threaded-record gate: load the masked tagged FROM/TO bytes from the overlapping root/reply records,
;                 fold them into a compare key with 308Dh, and emit 43h only for the narrow zero/FD..FF match case
;   0143h-015Ah = current-square descriptor gate: build a row from the board byte at square E,
;                 emit 4Dh when the row's first byte is zero, then emit 5Bh when the paired descriptor test also clears
; The tail at 015Bh-0162h contains tiny executable trampolines (JP 08C6h, then NOP/NOP/JP 096Bh),
; which matches the threaded early-search path that replays compact records through normal move handling.
tbl_compact_engine_script_data:
    ; 0100h-010Eh: selector-nibble dispatch with the 08h continuation fast-path.
tbl_compact_script_selector_dispatch:
    db 7Eh, E7h, CBh, 69h, 28h, 09h, 3Dh, FFh, EDh, 57h, 3Ch, 3Ch, 6Bh, 18h, 4Bh
    ; 010Fh-011Dh: first row-compare gates; 0116h and 011Dh are the 17h / 1Eh RST 38h tag sites.
tbl_compact_script_row_zero_gates:
    db 85h, 6Fh, 2Dh, 97h, BEh, 28h, 01h, FFh, 97h, 2Ch, 2Ch, BEh, 28h, 01h, FFh
    ; 011Eh-0142h: threaded-record compare against the masked overlapping root/reply bytes plus 308Dh.
tbl_compact_threaded_record_gate:
    db D9h, 2Ch, 7Eh, E6h, 77h, D9h, 47h, D9h, 2Ch, 7Eh, E6h, 77h, 2Dh, 2Dh, D9h
    db E5h, 6Fh, 80h, A7h, 1Fh, 47h, 3Ah, 8Dh, 30h, 86h, E1h, 20h, 09h, 7Dh, 2Fh
    db 80h, FEh, FDh, 38h, 02h, 3Ch, FFh
    ; 0143h-015Ah: current-square descriptor row gate; 014Ch and 015Ah are the 4Dh / 5Bh tag sites.
tbl_compact_square_descriptor_gate:
    db 6Bh, 7Eh, E7h, 85h, 6Fh, 97h, BEh, 20h, 0Fh, FFh, 7Dh, 93h, 85h, 6Fh, 3Ah
    db 8Dh, 30h, ADh, E6h, 40h, B6h, 20h, 01h, FFh
    ; 015Bh-0162h: tiny executable trampolines back into the generic search helpers.
tbl_compact_threaded_trampolines:
    db C3h, C6h, 08h, 00h, 00h, C3h, 6Bh, 09h    ; compact engine script / decision data

; -----------------------------------------------------------------------
; Short page-01 postprocess scriptlets used by search_branch_when_piece_present after the special-case path.
; They emit 1-3 extra RST 38h deltas before returning to the generic square scan.
; jumps from 0C74h
vector_script_postprocess:
    dec a
    jr nz,emit_remaining_postprocess_deltas
    ld a,2
; -----------------------------------------------------------------------
; Emit one scripted delta, then hand control back to the generic search helper.
; jumps from 016Fh, 0174h
emit_scripted_delta_and_resume_search:
    rst 38h
    jp resume_search_from_current_square
; -----------------------------------------------------------------------
; Emit the remaining one or two postprocess deltas for the compact page-01 script path.
; jumps from 0164h
emit_remaining_postprocess_deltas:
    dec a
    ld a,FEh
    jr z,emit_scripted_delta_and_resume_search
    rst 38h
    ld a,4
    jr emit_scripted_delta_and_resume_search
; -----------------------------------------------------------------------
; Executable page-01 piece scripts used with RST 38h.
; Entry points selected by the 00E7h-00F3h dispatch bytes:
;   0176h = knight ring, 0190h = king ring,
;   01AAh = rook/queen orthogonal sliders, 01C6h = bishop diagonal sliders.
; The scripts are executable bytecode, not passive data tables.
tbl_vector_script_01:
    db 3Eh, DFh, FFh, 3Eh, 02h, FFh, 3Eh, 0Dh, FFh, 3Eh, 04h, FFh, 3Eh, 1Ch, FFh, 3Eh
    db 04h, FFh, 3Eh, 0Dh, FFh, 3Eh, 02h, FFh, 18h, CBh, 3Eh, 0Fh, FFh, 3Eh, 01h, FFh
    db 3Eh, 01h, FFh, 3Eh, DEh, FFh, 3Eh, 01h, FFh, 3Eh, 01h, FFh, 3Eh, 0Eh, FFh, 3Eh
    db 02h, FFh, 18h, 33h, 3Eh, F0h, FFh, 28h, FBh, 6Bh, 3Eh, FFh, FFh, 28h, FBh, 6Bh
    db 3Eh, 01h, FFh, 28h, FBh, 6Bh, 3Eh, 10h, FFh, 28h, FBh, 6Bh, CBh, 46h, 28h, 17h
    db 3Eh, EFh, FFh, 28h, FBh, 6Bh, 3Eh, F1h, FFh, 28h, FBh, 6Bh, 3Eh, 11h, FFh, 28h
    db FBh, 6Bh, 3Eh, 0Fh, FFh, 28h, FBh, C3h, C6h, 08h

; -----------------------------------------------------------------------
; jumps from 0042h
; Update one square's sidecar byte in the 0x88 hole map.
; Sidecar format:
;   bits7-6 = positive-side control count, saturating at 3
;   bits5-4 = negative-side control count, saturating at 3
;   bits3-2 = positive-side least-valuable-attacker class (0=queen/king, 1=rook, 2=minor, 3=pawn)
;   bits1-0 = negative-side least-valuable-attacker class (0=queen/king, 1=rook, 2=minor, 3=pawn)
rst38_capture_or_special_case:
    ld a,(ram_piece_or_square_tmp)
    ld b,a
    ld a,(hl)
    add a,5
    cp 0Bh
    ld a,b
    jr c,merge_sidecar_control_metadata_slow_path
    xor (hl)
    jp p,merge_sidecar_control_metadata_slow_path
    ld a,(hl)
    xor d
    jp p,store_candidate_and_update_display
    exx
    inc l
    set 7,(hl)
    dec l
    exx
; -----------------------------------------------------------------------
; Slow path for occupied/special-square cases: fold control counts and least-valuable-attacker classes into the sidecar byte.
; jumps from 01EAh, 01EDh
merge_sidecar_control_metadata_slow_path:
    push hl
    ld hl,ram_blink_or_random1
; -----------------------------------------------------------------------
; Walk the cached square list until the current square id matches, then merge the corresponding control metadata.
; jumps from 0206h
scan_cached_square_list_for_match:
    inc l
    bit 7,(hl)
    jr nz,resume_sidecar_merge_after_cached_square_scan
    ld a,e
    cp (hl)
    jr nz,scan_cached_square_list_for_match
    inc l
    inc l
    inc l
    inc l
    inc l
    ld a,i
    cp (hl)
    pop hl
    jp nz,return_board_piece_or_zero
; -----------------------------------------------------------------------
; Overlapping entry used by the cached-square sentinel path.
; The linear fallthrough consumes FE E1 as CP E1h, while the sentinel branch lands on the E1h byte and executes it as POP HL.
resume_sidecar_merge_after_cached_square_scan_compare_prelude:
    db 0FEh
resume_sidecar_merge_after_cached_square_scan: pop hl
    ld a,b
    push hl
    set 3,l
    bit 3,a
    ld a,(hl)
    jr z,increment_negative_control_count_saturated
    or CFh
    xor FFh
    ld a,(hl)
    jr z,keep_positive_control_count_field
    add a,10h
    ld (hl),a
; -----------------------------------------------------------------------
; Keep only the updated two-bit control-count field after the positive-side merge path.
; jumps from 0224h
keep_positive_control_count_field:
    and 3
    jr merge_least_valuable_attacker_class
; -----------------------------------------------------------------------
; Increment the negative-side control-count field, saturating at 3.
; jumps from 021Dh
increment_negative_control_count_saturated:
    add a,40h
    jr c,extract_negative_attacker_bits
    ld (hl),a
; -----------------------------------------------------------------------
; jumps from 022Fh
extract_negative_attacker_bits:
    ld a,(hl)
    and 0Ch
; -----------------------------------------------------------------------
; Merge the least-valuable-attacker class nibble derived from the piece lookup table.
; jumps from 022Bh
merge_least_valuable_attacker_class:
    ld h,a
    ld a,b
    add a,D3h
    call lookup_page0_byte
    add a,h
    ld h,30h
    xor FFh
    jp m,finish_sidecar_merge_and_check_directional_flags
    add a,(hl)
    ld (hl),a
; -----------------------------------------------------------------------
; Finish the sidecar merge and, for sliding pieces, decide whether the square also updates directional status flags.
; jumps from 0241h
finish_sidecar_merge_and_check_directional_flags:
    pop hl
    exx
    pop de
    push de
    ld a,e
    exx
    cp AAh
    ret c
    ld a,(hl)
    or a
    ret z
    xor b
    ret m
    ld a,(hl)
    ld b,a
    xor FFh
    jp m,normalize_signed_piece_to_direction_group
    inc a
    ld b,a
; -----------------------------------------------------------------------
; Normalize the signed piece code into the compact rook-vs-bishop/queen group used by the directional-flag merge.
; jumps from 0258h
normalize_signed_piece_to_direction_group:
    ld h,4
    exx
    ld a,e
    exx
    cp C6h
    jr c,compare_direction_group_against_existing_flags
    ld h,3
; -----------------------------------------------------------------------
; Compare the coarse directional group against the existing flag byte and keep only meaningful changes.
; jumps from 0264h
compare_direction_group_against_existing_flags:
    ld a,h
    ld h,30h
    xor b
    ret z
    ld a,b
    cp 5
    ret
; -----------------------------------------------------------------------
; page-02 front-end state/phase lattice.
; lookup_de_from_state_phase_table enters at 0271h and treats ram_key_state as the low-byte offset,
; while 3081h contributes the 4-byte phase stride.
; Each fetched DE pair is a tagged transition descriptor rather than just two plain squares:
;   E bits0-2/4-6 = tagged FROM, D bits0-2/4-6 = tagged TO
;   D bit3        = accept the currently visible move pair without literal DE compare
;   E bit3        = mismatch/retry family marker; allows advance_key_repeat_state instead of immediate threaded handoff
;   D bit7        = force ram_key_state back to FFh before the engine/control handoff
;   E bit7        = request the CHECK LED after the accepted visible-board update
; Several offsets map directly onto opening-development families when phases 1..3 are read in order:
;   FCh = white king-pawn family, 54h = white queen-pawn family,
;   FEh = black ...e5 family, 3Eh = Sicilian family, 1Eh = French family, 56h = ...d5/...e6 development family.
; The tail of the same page-02 block is later recycled by rebuild_from_to_display for rank/file glyph lookups.
tbl_frontend_state_phase_pairs:
    db 34h, 1Ch, 44h, 6Ch, 25h, 06h, 52h, 71h, 32h, 0Dh, 42h, 75h, 22h, 12h, 55h, 76h
    db 33h, 13h, 33h, 44h, B3h, 22h, B1h, C2h, 41h, 05h, 50h, 60h, B0h, 41h, D5h, 76h
    db 34h, 14h, 54h, 64h, 33h, 13h, 43h, 63h, 22h, 09h, 55h, 76h, 46h, 0Ah, 64h, 75h
    db C4h, 34h, E3h, 55h, C4h, 34h, C2h, 62h, C4h, 34h, 63h, 55h, 7Fh, 77h, C2h, 62h
    db 34h, 14h
tbl_display_rank_glyphs:
    db 42h, 6Ah, 25h, 06h, 53h, 63h, 33h, 13h
    db 33h
tbl_display_file_glyphs:
    db 42h, 33h, 25h, 55h, 76h, 22h, 01h, 56h
    db 66h, 94h, 05h, E6h, 75h, 33h, 13h, 43h, 63h, 32h, 12h, 54h, 6Ch
    db 22h, 01h, 55h, 76h, C6h, 02h, E3h, 71h, D2h, 62h, A5h, 06h
    ; The tail of this page-02 table is also reused by rebuild_from_to_display:
    ;   tbl_display_rank_glyphs = 02B3h-02BAh, selected through C=B2h after RST 28h
    ;   tbl_display_file_glyphs = 02BCh-02C3h, selected through C=BBh from the square low nibble

; -----------------------------------------------------------------------
; Index a page-02 table with the low nibble of A, store one byte to (HL), then advance HL.
; calls from 02F2h, 02F9h, 02FEh; jumps from 0304h
table_lookup_store_byte:
    inc a
    and 0Fh
    add a,c
    ld c,a
    ld a,(bc)
    ld (hl),a
    inc hl
    ld a,e
    ret
; -----------------------------------------------------------------------
; Rebuild the 4 display digits from the displayed move pair.
; The code renders the high byte first and the low byte second, so the left window is the high byte (3087h).
; calls from 05CBh, 07B8h, 0BEDh; jumps from 0314h
rebuild_from_to_display:
    ld hl,(ram_move_to_square)
    ex de,hl
    ld hl,ram_disp_from_lo
    ld bc,BBh                                  ; Shared tail lookup at 02BCh-02C3h: file glyph map indexed by square low nibble + 1.
    ld a,d
    call table_lookup_store_byte
    ld c,B2h                                   ; Shared tail lookup at 02B3h-02BAh: rank glyph map indexed by square high nibble + 1.
    ld a,d
    rst 28h
    call table_lookup_store_byte
    ld c,BBh
    call table_lookup_store_byte
    rst 28h
    ld c,B2h
    jr table_lookup_store_byte
; -----------------------------------------------------------------------
; Clear most UI state, preset from/to to FFh, then rebuild the display windows.
; calls from 047Eh, 0568h, 06D7h, 0706h, 0798h
clear_ui_state_and_rebuild_display:
    ld hl,ram_frontend_flags1
    ld b,5
    sub a
; -----------------------------------------------------------------------
; Clear five bytes of UI/front-end state, then seed the move window with FF/FF before rebuilding the display.
; jumps from 030Eh
clear_frontend_state_bytes_loop:
    ld (hl),a
    inc hl
    djnz clear_frontend_state_bytes_loop
    dec hl
    dec (hl)
    dec hl
    dec (hl)
    jr rebuild_from_to_display
; -----------------------------------------------------------------------
; Sort-like routine over a small table of move records starting at IX.
; jumps from 033Ah
sort_move_records_at_ix:
    ld l,(ix)
    ld h,(ix+1)
; -----------------------------------------------------------------------
; Compare the current 2-byte key at IX+0 against the peer key at IX+4 to decide whether the pair needs swapping.
; calls from 092Bh
compare_move_record_keys_at_ix:
    ld e,(ix+4)
    ld d,(ix+5)
    and a
    sbc hl,de
    ret z
    ret m
    ld c,4
; -----------------------------------------------------------------------
; Swap the two 4-byte move-record entries selected by IX and IX+4.
; jumps from 0338h
swap_move_record_pair_loop:
    ld h,(ix)
    ld l,(ix+4)
    ld (ix+4),h
    ld (ix),l
    inc ix
    dec c
    jr nz,swap_move_record_pair_loop
    djnz sort_move_records_at_ix
    ret
; -----------------------------------------------------------------------
; Decode the page-30 move-record window for the current active search stage.
; 308Eh supplies the base offset into page 0Ch, 308Fh the active-stage mask, and 3091h the currently selected one-bit stage cursor.
; The returned pair selects the active page-30 move-record window:
;   first byte  -> low-byte base of the sortable 4-byte record pool
;   second byte -> record count for that pool; 035Bh-035Ch immediately convert it into a byte count by << 2
; calls from 0943h, 096Fh, 0908h
decode_stage_record_window:
    exx
; -----------------------------------------------------------------------
; Pick the page-0C descriptor pair for the currently active stage bit / schedule mask combination.
; calls from 0A0Ch
pick_stage_descriptor_pair:
    ld a,(ram_schedule_base_offset)
    ld c,a
    ld b,0Ch
    ld a,(ram_schedule_stage_mask)
    ld d,a
    and (iy+11h)
; -----------------------------------------------------------------------
; Walk the one-hot stage bit until the matching descriptor pair is found.
; jumps from 0350h, 0354h
walk_stage_bits_until_descriptor_match:
    rrca
    jr c,return_stage_window_base_and_byte_count
    rrc d
    jr nc,walk_stage_bits_until_descriptor_match
    inc c
    inc c
    jr walk_stage_bits_until_descriptor_match
; -----------------------------------------------------------------------
; Return the selected page-30 record-window base and convert the stored record count into a byte count.
; jumps from 034Ch
return_stage_window_base_and_byte_count:
    ld a,(bc)
    ld e,a
    ld d,h
    inc c
    ld a,l
    ex af,af'
    ld a,(bc)
    ld c,a
    sla c
    sla c
    ld b,0
    ret
; -----------------------------------------------------------------------
; Initial 8x8 square template.
; During cold start only the upper nibble is copied into the live 0x88 board:
;   stored upper nibble 8 -> 08h + F8h = 00h  = empty
;   stored upper nibble 9 -> 09h + F8h = 01h  = +pawn
;   stored upper nibble A -> 0Ah + F8h = 02h  = +knight
;   stored upper nibble B -> 0Bh + F8h = 03h  = +bishop
;   stored upper nibble C -> 0Ch + F8h = 04h  = +rook
;   stored upper nibble D -> 0Dh + F8h = 05h  = +queen
;   stored upper nibble E -> 0Eh + F8h = 06h  = +king
;   stored upper nibble 7 -> 07h + F8h = FFh  = -pawn
;   stored upper nibble 6 -> 06h + F8h = FEh  = -knight
;   stored upper nibble 5 -> 05h + F8h = FDh  = -bishop
;   stored upper nibble 4 -> 04h + F8h = FCh  = -rook
;   stored upper nibble 3 -> 03h + F8h = FBh  = -queen
;   stored upper nibble 2 -> 02h + F8h = FAh  = -king
;
; The lower nibble is *not* used to build the live board. It is looked up later by 0CE4h/lookup_initial_square_nibble
; as a compact opening-phase square class / repeat count, so even empty ranks can legitimately differ byte-to-byte.
tbl_initial_board_hi_nibbles:
    db C1h, A1h, B1h, D1h, E1h, B1h, A1h, C1h    ; row 0: +R +N +B +Q +K +B +N +R
    db 91h, 91h, 91h, 92h, 92h, 91h, 91h, 91h    ; row 1: +P +P +P +P +P +P +P +P (low-nibble center files differ)
    db 81h, 81h, 82h, 83h, 83h, 82h, 81h, 81h    ; row 2: empty row, low nibble = opening-square class only
    db 81h, 82h, 83h, 84h, 84h, 83h, 82h, 81h    ; row 3: empty row, low nibble = opening-square class only
    db 81h, 82h, 83h, 84h, 84h, 83h, 82h, 81h    ; row 4: empty row, low nibble = opening-square class only
    db 81h, 81h, 82h, 83h, 83h, 82h, 81h, 81h    ; row 5: empty row, low nibble = opening-square class only
    db 71h, 71h, 71h, 72h, 72h, 71h, 71h, 71h    ; row 6: -P -P -P -P -P -P -P -P (low-nibble center files differ)
    db 41h, 61h, 51h, 31h, 21h, 51h, 61h, 41h    ; row 7: -R -N -B -Q -K -B -N -R

; -----------------------------------------------------------------------
; Generate a short beep by toggling port bit 7, unless ram_frontend_flags0.bit0 is set.
; All currently identified engine-response tones funnel through this generic path; no opening-book-only beep routine
; has been isolated in the ROM so far.
; calls from 0536h, 0BE6h, 0B6Bh
beep_if_enabled:
    bit 0,(iy+2)
    ret nz
    push bc
    ld bc,80h
    sub a
; -----------------------------------------------------------------------
; Outer tone loop: toggle port bit 7 and keep the pulse train running for BC iterations.
; jumps from 03B8h
beep_outer_pulse_toggle_loop:
    cpl
    and 80h
    out (0007h),a
; -----------------------------------------------------------------------
; Inner busy-wait for one pulse width.
; jumps from 03B5h
beep_inner_pulse_wait_loop:
    dec b
    jr nz,beep_inner_pulse_wait_loop
    dec c
    jr nz,beep_outer_pulse_toggle_loop
    pop bc
    ret
; -----------------------------------------------------------------------
; Merge castling-disable bits into C according to the piece found on a probed square.
; A white king on the probed square disables both white castling sides (bits0-1),
; and a black king disables both black sides (bits2-3).
; calls from 0BB8h, 0BBEh
merge_castling_disable_bits_from_king_square:
    and 77h
    ld l,a
    ld a,(hl)
    cp 6
    jr z,disable_white_castling_both_sides
    cp FAh
    ret nz
    ld a,0Ch
    jr or_castling_disable_bits_into_c
; -----------------------------------------------------------------------
; White king detected: disable both white castling sides.
; jumps from 03C2h
disable_white_castling_both_sides:
    ld a,3
; -----------------------------------------------------------------------
; Final OR-merge used by merge_castling_disable_bits_from_king_square.
; jumps from 03C9h
or_castling_disable_bits_into_c:
    or c
    ld c,a
    ret
; -----------------------------------------------------------------------
; Apply the displayed move pair in RAM to the 0x88 board.
; With the corrected byte order, the routine copies FROM->TO and clears the source square.
; calls from 074Ah, 05F8h, 0604h, 06C2h
apply_move_from_ram_pair:
    ld hl,(ram_move_to_square)
    ld b,l
    ld l,h
    ld h,30h
    ld a,(hl)
    ld (hl),0
    ld l,b
    ld (hl),a
    ret
; -----------------------------------------------------------------------
; Advance the front-panel decode / repeat state stored at 308Ch.
; These values are not board squares or engine data; they are low-byte offsets into the page-02 DE-pair lattice.
; lookup_de_from_state_phase_table adds the current phase stride (4 * 3081h) and then fetches the DE pair used by the front-end validator.
; Transition chains in the state lattice:
;   FCh -> 54h -> 60h          = default-start retry family
;   FEh -> 3Eh -> 1Eh -> 2Ch   = computer-first / problem-start family while 3081h == 01h
;   FEh -> 10h -> 0Eh          = later-phase reduction of that same family once 3081h > 01h
;   38h -> 1Ah -> 18h -> 24h   = in-game retry family after a committed move
;   F8h -> 08h                 = randomized first-move follow-up family
; calls from 066Eh, 0699h
advance_key_repeat_state:
    ld hl,ram_key_state
    ld a,(hl)
    ld (hl),8
    cp F8h
    ret z
    ld (hl),54h
    cp FCh
    ret z
    ld (hl),3Eh
    cp FEh
    jr nz,advance_key_repeat_state_tail
    rst 30h
    dec a
    ret z
    ld (hl),10h
    ret
; -----------------------------------------------------------------------
; General tail of the 308Ch front-end decode-state transition chain.
; jumps from 03EFh
advance_key_repeat_state_tail:
    ld (hl),1Eh
    cp 3Eh
    ret z
    ld (hl),2Ch
    cp 1Eh
    ret z
    ld (hl),1Ah
    cp 38h
    ret z
    ld (hl),24h
    cp 18h
    ret z
    ld (hl),60h
    ret
; -----------------------------------------------------------------------
; Lookup the tagged DE transition pair used by the front-end state machine.
; A = ram_key_state offset; 3081h contributes a 4-byte stride, so the effective address is 0271h + A + 4 * ram_phase_turn_counter.
; calls from 0656h, 069Fh
lookup_de_from_state_phase_table:
    ld bc,0271h
    add a,c
    add a,(hl)
    add a,(hl)
    add a,(hl)
    add a,(hl)
    ld c,a
; -----------------------------------------------------------------------
; calls from 0674h
fetch_followup_de_transition_pair:
    ld a,(bc)
    ld d,a
    inc c
    ld a,(bc)
    ld e,a
    ret
; -----------------------------------------------------------------------
; Map a signed piece code to a small property byte via the page-0 table at 00E0h.
; calls from 07D0h, 0A85h, 0D0Ch
lookup_piece_property:
    add a,E0h
; -----------------------------------------------------------------------
; calls from 08BCh, 0239h
lookup_page0_byte:
    push bc
    ld b,0
    ld c,a
    ld a,(bc)
    pop bc
    ret
; -----------------------------------------------------------------------
; Load the current level descriptor and update the front-panel banner / search workspace.
; The copied 4-byte window overlaps in ROM, but only 308Eh-3090h remain long-lived:
; 308Dh is quickly reused as ram_piece_or_square_tmp.
; The workspace reset here pre-fills 30B9h-30E3h with B9h before the staged search code narrows it further.
; The same level descriptor also gates the opening style:
; levels 1/3/4/7 choose the Sicilian cluster after 1.e4, while 2/5/6 choose the ...e5 cluster.
; calls from 0727h, 07BEh
level_setup_banner_and_params:
    exx
; -----------------------------------------------------------------------
; Core loader: copy the per-level descriptor, blank the banner state, and prefill the shared stage pool.
; calls from 061Ch
load_level_descriptor_banner_workspace:
    ld a,5Ch
    ld hl,ram_blink_or_random0
    ld (hl),a
    call write_ne591_pattern
    ld a,0Fh
    out (0007h),a
    ld l,80h
    ld b,(hl)
    ld l,8Dh
    ex de,hl
    ld hl,0C73h
; -----------------------------------------------------------------------
; Advance through the compressed per-level descriptor table in 3-byte steps.
; jumps from 0440h
advance_level_descriptor_by_triplets:
    inc l
    inc l
    inc l
    djnz advance_level_descriptor_by_triplets
    call copy4_bytes_hl_to_de
    ex de,hl
    ld (hl),80h
    sub a
    inc l
    ld (hl),a
    ld l,E3h
    ld a,B9h
    ld b,2Bh
; -----------------------------------------------------------------------
; Fill 30B9h..30E3h with the B9h sentinel byte used by the staged move-record workspace.
; jumps from 0453h
fill_stage_workspace_with_b9_sentinel:
    ld (hl),a
    dec l
    djnz fill_stage_workspace_with_b9_sentinel
    ld l,B2h
    exx
    ret
; -----------------------------------------------------------------------
; Cold start: wait until no key is held, build the 0x88 board from the ROM template, clear UI state, then enter the polling loop.
; jumps from 0005h
cold_start:
    ld hl,ram_board_0x88
    ld bc,tbl_initial_board_hi_nibbles
    ld sp,3100h
    ld a,3Fh                                 ; All six front-panel outputs are enabled while waiting for key release.
    out (0007h),a
; -----------------------------------------------------------------------
; Wait until no keypad row is active before constructing the initial board/UI state.
; jumps from 046Ah
wait_for_keypad_release_before_cold_start:
    in a,(0007h)
    and 0Fh
    jr nz,wait_for_keypad_release_before_cold_start
; -----------------------------------------------------------------------
; Copy the 8x8 ROM board template into the live 0x88 board, skipping the hole squares.
; jumps from 0476h, 047Ah
copy_initial_board_template_into_0x88:
    ld a,(bc)                                ; Copy only the upper nibble of each template byte into the 0x88 board and bias it by F8h.
    rst 28h
    add a,F8h
    ld (hl),a
    inc l
    inc bc
    ld a,8
    and l
    jr z,copy_initial_board_template_into_0x88
    add a,l                                  ; Skip the 0x88 holes by adding 8 whenever file 8 is reached.
    ld l,a
    jp p,copy_initial_board_template_into_0x88
    inc a
    call clear_ui_state_and_rebuild_display
    ld l,82h
    sub a                                    ; ram_frontend_flags0/1 are cleared here via the backward stores through 3082h..3080h.
    ld (hl),a
    dec hl
    inc a
    ld (hl),a
    dec hl
    ld (hl),a
    ld a,FCh                                 ; Initial key/front-end state = FCh.
    ld (ram_key_state),a
    ld l,F4h
    call copy4_from_page0_to_display         ; Show the level banner prefix from 00F4h ("CL 1").
    ld d,FFh
    ld h,30h
    exx
    sub a
    ld e,a
; -----------------------------------------------------------------------
; Main polling loop: multiplex 4 digits + 2 LEDs, read the keypad through the same mux, and debounce a key code in D/E.
; jumps from 052Ah, 0C04h
main_scan_loop:
    ld b,EFh
; -----------------------------------------------------------------------
; One full poll slice: select the active digit/column, sample the keypad rows, and accumulate debounce state.
; jumps from 0527h
scan_mux_digit_and_keypad_slice:
    ld a,b
    rst 28h
    or F0h
    cpl
    out (0007h),a                            ; Write scan pattern: D0-D3 select a digit / keypad column, D4-D5 drive CHECK / I LOSE.
    in a,(0007h)                             ; Read the keyboard rows through the same mux.
    cpl
    and 0Fh
    ld c,a
    ld a,b
    and F0h
    or c
    ld c,a
    or F0h
    cpl
    or a
    jr z,decay_or_reset_debounce_on_idle_slice
    ld a,e
    or a
    jr nz,continue_debounce_for_active_key_pattern
    ld d,c
    jr seed_debounce_counter_for_new_pattern
; -----------------------------------------------------------------------
; Debounce path while the same nonzero key pattern is still present.
; jumps from 04B7h
continue_debounce_for_active_key_pattern:
    cp 8
    jr nc,saturate_debounce_counter_for_noisy_pattern
    ld a,c
    cp d
    jr nz,clear_debounce_state
    ld a,e
    cp 5
    jr z,finish_poll_slice_and_refresh_outputs
    cp 4
    jr z,handle_debounced_key
; -----------------------------------------------------------------------
; First observation of a candidate key pattern: store it in D and start the debounce counter in E.
; jumps from 04BAh
seed_debounce_counter_for_new_pattern:
    inc e
    jr finish_poll_slice_and_refresh_outputs
; -----------------------------------------------------------------------
; No key currently active on this poll slice: decay or reset the debounce state if the previously seen pattern has gone away.
; jumps from 04B3h
decay_or_reset_debounce_on_idle_slice:
    ld a,d
    or 0Fh
    cp b
    jr nz,finish_poll_slice_and_refresh_outputs
    ld a,e
    cp 5
    jr nz,continue_debounce_decay
; -----------------------------------------------------------------------
; Saturation path for obviously noisy or multi-row readings.
; jumps from 04BEh
saturate_debounce_counter_for_noisy_pattern:
    ld e,0Ch
    jr finish_poll_slice_and_refresh_outputs
; -----------------------------------------------------------------------
; Continue decaying the debounce counter until the stale candidate fully expires.
; jumps from 04D9h
continue_debounce_decay:
    jr c,clear_debounce_state
    inc e
    ld a,e
    cp 0Fh
    jr nz,finish_poll_slice_and_refresh_outputs
; -----------------------------------------------------------------------
; Fully clear the debounce counter/state.
; jumps from 04C2h, 04DFh
clear_debounce_state:
    ld e,0
; -----------------------------------------------------------------------
; End-of-scan housekeeping: update blink state and refresh the four display digits / LEDs once.
; jumps from 04D4h, 04DDh, 04C7h, 04CEh, 04E5h
finish_poll_slice_and_refresh_outputs:
    push de
    push bc
    ld hl,ram_blink_or_random1
    inc (hl)
    ld a,(hl)
    ld l,83h
    res 1,(hl)
    bit 0,(hl)
    jr z,begin_display_refresh_sweep
    or a
    jp p,begin_display_refresh_sweep
    set 1,(hl)                               ; If blinking is enabled, raise the one-refresh output-blank latch on alternating scans.
; -----------------------------------------------------------------------
; Start the 4-digit refresh sweep with digit-select mask 0001b and display buffer pointer 3088h.
; jumps from 04F6h, 04F9h
begin_display_refresh_sweep:
    ld d,1
    ld l,88h
; -----------------------------------------------------------------------
; jumps from 051Dh
refresh_next_display_digit:
    ld a,(hl)
    and 7Fh
    call write_ne591_pattern
    ld a,(ram_led_select_bits)               ; ram_led_select_bits contributes CHECK/I LOSE during digit refresh.
    or d
    bit 1,(iy+3)
    jr nz,seed_digit_hold_delay
    out (0007h),a                            ; Display output is suppressed when ram_frontend_flags1.bit1 is set.
; -----------------------------------------------------------------------
; Tiny digit-hold delay so the multiplexed outputs stay visible.
; jumps from 0510h
seed_digit_hold_delay:
    ld b,0
; -----------------------------------------------------------------------
; Busy-wait loop for one digit dwell time.
; jumps from 0516h
digit_hold_delay_loop:
    djnz digit_hold_delay_loop
    inc hl
    rlc d
    bit 4,d
    jr z,refresh_next_display_digit
    sub a
    call write_ne591_pattern
; -----------------------------------------------------------------------
; Exit the refresh slice and either continue the scan ring or restart the main polling loop.
; jumps from 07BBh
exit_refresh_slice_and_resume_scan:
    pop bc
    pop de
    rlc b
    jp c,scan_mux_digit_and_keypad_slice
    jp main_scan_loop
; -----------------------------------------------------------------------
; A key has been debounced. Dispatch front-panel commands and board-square entry here.
; jumps from 04CBh
handle_debounced_key:
    inc e
    push de
    push bc
    ld hl,ram_frontend_flags1
    ld c,(hl)
    dec l
    ld b,(hl)
    call beep_if_enabled                     ; Audible key-click / command acknowledgment.
    ld a,d
    ld d,30h
    cp 7Eh                                   ; Compare against KEY_RE (7Eh).
    jr nz,key_change_board_handler
    sub a
    call write_ne591_pattern
    rst 0                                    ; RST 00h = hard reset.
; -----------------------------------------------------------------------
; CB key (Change Board / computer-first path before the first move).
; jumps from 053Eh
key_change_board_handler:
    cp BEh                                   ; Compare against KEY_CB (BEh).
    jr nz,key_clear_handler
    rst 30h
    dec a                                     ; Before the first committed move (3081h = 01h), CB enters the computer-first opening path.
                                              ; On levels 1-4 that path preloads/applies d2-d4; on 5-7 it falls through to the side/orientation toggle path instead.
    jp z,trigger_engine_or_problem_action
    ld a,(hl)
    xor 1
    ld (hl),a
    sub a
; -----------------------------------------------------------------------
; CL key (Clear).
; jumps from 0547h
key_clear_handler:
    cp DEh                                   ; Compare against KEY_CL (DEh).
    jr nz,key_level_handler
    bit 1,b
    jr z,clear_reset_tail
    bit 2,c
    jr z,clear_reset_tail
    ld l,84h
    ld e,(hl)
    sub a
    ld (de),a
    jr walk_review_cursor_over_board
; -----------------------------------------------------------------------
; Shared clear/reset tail for CL and related mode changes.
; jumps from 0559h, 055Dh, 06EAh
clear_reset_tail:
    res 1,(hl)
    call clear_ui_state_and_rebuild_display
    sub a
; -----------------------------------------------------------------------
; LV key (Level). Increment ram_level and show the "CL n" banner.
; jumps from 0555h
key_level_handler:
    cp 7Dh                                   ; Compare against KEY_LV (7Dh).
    jr nz,key_position_verification_handler
    ld l,80h                                 ; LV: level increments, wraps, and the rightmost display digit is replaced with the new level number.
    ld a,(ram_disp_from_hi)
    cp 38h
    jr nz,show_current_level_banner
    inc (hl)
    ld a,7
    cp (hl)
    jr nc,show_current_level_banner
    ld (hl),1
; -----------------------------------------------------------------------
; jumps from 0577h, 057Dh
show_current_level_banner:
    ld a,B2h
    add a,(hl)
    ld l,F4h
    call copy4_from_page0_to_display
    ld l,a
    ld a,(hl)
    ld (ram_disp_to_hi),a
    sub a
; -----------------------------------------------------------------------
; PV key (Position Verification) / board review handling.
; jumps from 056Eh
key_position_verification_handler:
    cp EDh                                   ; Compare against KEY_PV (EDh).
    jr nz,key_enter_handler
    inc l                                    ; PV: enters the position-verification flow.
    inc l
    bit 2,c
    jr nz,advance_pv_cursor_state
    dec l
    set 2,(hl)
    inc l
    ld (hl),FFh
; -----------------------------------------------------------------------
; Advance the PV / board-review cursor state.
; jumps from 0597h, 05B7h
advance_pv_cursor_state:
    inc (hl)
; -----------------------------------------------------------------------
; Walk the review/edit cursor over the 0x88 board, skipping the file-8 holes.
; jumps from 0564h, 05E3h, 0785h
walk_review_cursor_over_board:
    ld a,(hl)
    bit 3,a
    jr z,load_piece_for_pv_render                            ; 3084h is walked as a 0x88 board cursor here, skipping the hole files.
    add a,8
    and 77h
    ld (hl),a
; -----------------------------------------------------------------------
; Load the currently selected square so PV/edit mode can render its piece identity.
; jumps from 05A3h
load_piece_for_pv_render:
    ld e,a
    ld a,(de)
    ld c,F8h
    or a
    jr nz,classify_signed_piece_for_pv_display
    bit 1,(iy+2)
    jr nz,publish_pv_square_and_piece
    jr advance_pv_cursor_state
; -----------------------------------------------------------------------
; Convert the signed piece on the selected square into the coarse display class (friendly/enemy and piece family).
; jumps from 05AFh
classify_signed_piece_for_pv_display:
    ld c,4
    jp p,convert_piece_magnitude_to_pv_glyph_offset
    ld c,8
    cpl
    inc a
; -----------------------------------------------------------------------
; Convert the 1..6 piece magnitude into the display-table offset used by the PV window.
; jumps from 05BBh
convert_piece_magnitude_to_pv_glyph_offset:
    rlca
    dec a
    rst 20h
; -----------------------------------------------------------------------
; Publish the selected square/piece pair into 3086h/3087h and rebuild the visible move window.
; jumps from 05B5h
publish_pv_square_and_piece:
    add a,c
    ld h,e
    ld l,a
    ld (ram_move_to_square),hl
; -----------------------------------------------------------------------
; Rebuild the current visible move/piece window without changing the already prepared 3086h/3087h pair.
; The EN/PV path re-enters here once the current review selection has already been published.
rebuild_current_visible_pair_after_pv_publish:
    call rebuild_from_to_display
; -----------------------------------------------------------------------
; Common "clear A" fallthrough used by the EN / PV state machine.
; jumps from 05E7h, 0618h
clear_a_for_enter_pv_fallthrough:
    sub a
; -----------------------------------------------------------------------
; EN key (Enter). Accept the current selection / current front-end state.
; jumps from 0591h
key_enter_handler:
    cp EEh                                   ; Compare against KEY_EN (EEh).
    jp nz,key_double_move_handler
    bit 1,(hl)
    jr z,handle_enter_while_selection_active
    inc hl
    bit 2,(hl)
    jr z,handle_enter_while_selection_active
    inc hl
    ld e,(hl)
    ld a,(de)
    cpl
    inc a
    ld (de),a
    jr walk_review_cursor_over_board
; -----------------------------------------------------------------------
; EN when the front-end is still in selection mode: either arm a commit or branch to the engine handoff.
; jumps from 05D6h, 05DBh
handle_enter_while_selection_active:
    bit 2,c
    jr nz,clear_a_for_enter_pv_fallthrough
    bit 3,c
    jr z,handle_enter_with_full_move_pair
    set 2,(hl)
    set 4,(hl)
    inc l
    res 3,(hl)
    ld l,8Ch                                 ; 308Ch is forced to FFh before the front-end asks for the engine response.
    ld (hl),FFh
    call apply_move_from_ram_pair
    jp load_doub_message_ptr
; -----------------------------------------------------------------------
; EN when a full move pair already exists: if 3082h.bit2 is set, this is the second leg of a double move;
; otherwise fall through into the normal move-accept/engine path.
; jumps from 05EBh
handle_enter_with_full_move_pair:
    bit 2,(hl)
    jr z,validate_visible_move_against_state_pair
    res 2,(hl)
    call apply_move_from_ram_pair
    exx
    jp unwind_dispatch_frame_before_engine_entry
; -----------------------------------------------------------------------
; Compare the current move/window contents against the decode state in 308Ch and decide the next front-end transition.
; jumps from 0600h, 0671h
validate_visible_move_against_state_pair:
    ld hl,(ram_move_to_square)
    ex de,hl
    ld a,(ram_key_state)
    ld b,a
    inc a
    jr nz,handle_cb_first_move_special_case
    bit 7,e
    jr nz,clear_a_for_enter_pv_fallthrough
; -----------------------------------------------------------------------
; Mismatch/side path: seed the threaded handoff header and drop into the engine/search setup.
; jumps from 066Ch
seed_threaded_root_and_enter_search:
    pop bc
    pop bc
    call load_level_descriptor_banner_workspace
    exx
    ld l,ADh                                  ; Seed 30ADh: base of the lower/root threaded move record.
    exx
    sub a
    ld (ram_search_stage_cursor),a
    dec a
    ld (ram_key_state),a
    jp clear_sidecar_map_and_begin_search
; -----------------------------------------------------------------------
; Special first-move CB path: before any committed move, mirror the orientation/setup bookkeeping used by the computer-first start.
; jumps from 0614h
handle_cb_first_move_special_case:
    ld hl,ram_phase_turn_counter
    ld a,(hl)
    dec a
    jr nz,compare_visible_move_with_expected_pair
    bit 7,e
    jr z,compare_visible_move_with_expected_pair
    inc (hl)                                 ; Special first-move path: if CB was used before any move, mirror the initial setup/orientation bookkeeping.
    ld hl,3003h
    inc (hl)
    inc l
    dec (hl)
    ld l,73h
    dec (hl)
    inc l
    inc (hl)
    ld hl,6343h
    ld a,r
    rrca
    jr c,store_special_cb_first_move_state
    inc h
    inc l
; -----------------------------------------------------------------------
; Store the seeded front-end key state for the computer-first/CB special case.
; jumps from 064Bh
store_special_cb_first_move_state:
    ld a,FFh
    jp store_randomized_key_state_for_handoff
; -----------------------------------------------------------------------
; Decode the currently expected DE transition pair from 308Ch and compare it against the visible FROM/TO selection.
; E carries the expected tagged FROM, D the expected tagged TO. D.bit3 bypasses the literal compare.
; jumps from 0633h, 0637h
compare_visible_move_with_expected_pair:
    ld a,b
    push de
    call lookup_de_from_state_phase_table
    pop hl
    bit 3,d
    jr nz,accept_selection_and_fetch_followup_pair
    ld a,e
    and 77h
    cp h
    jr nz,reject_selection_and_advance_state
    ld a,d
    and 77h
    cp l
    jr z,accept_selection_and_fetch_followup_pair
; -----------------------------------------------------------------------
; Rejected selection: either restart the threaded handoff immediately, or advance the DE-transition family through 308Ch.
; E.bit3 distinguishes the retry/advance families from the direct threaded-handoff families.
; jumps from 0662h
reject_selection_and_advance_state:
    bit 3,e
    jr z,seed_threaded_root_and_enter_search
    call advance_key_repeat_state
; -----------------------------------------------------------------------
; Retry the validation loop after a randomized/advanced decode-state transition.
; jumps from 068Ah
retry_state_pair_validation:
    jr validate_visible_move_against_state_pair
; -----------------------------------------------------------------------
; Accepted selection: fetch the follow-up DE transition pair and normalize the follow-up state in 308Ch.
; For the initial FCh family, the first accepted move bumps 3081h and then randomizes the follow-up root
; between 38h and F8h before continuing into the next phase of the lattice.
; jumps from 065Ch, 0668h
accept_selection_and_fetch_followup_pair:
    inc c
    call fetch_followup_de_transition_pair
    ld hl,ram_key_state                      ; ram_key_state is remapped through the front-end decode table.
    ld a,(hl)
    cp FCh
    jr nz,secondary_state_advance_after_accept
    ld a,l
    ld l,81h
    inc (hl)                                 ; Advance the board-action / phase counter before committing this decoded transition.
    ld l,a
    ld (hl),38h
    ld a,r
    rrca
    rrca
    jr c,retry_state_pair_validation
    ld (hl),F8h
    jr normalize_key_state_after_accept
; -----------------------------------------------------------------------
; Secondary state-advance path used when the accepted transition still carries the retry-family marker in E.bit3.
; jumps from 067Dh
secondary_state_advance_after_accept:
    bit 3,e
    jr z,normalize_key_state_after_accept
    ld a,r
    rrca
    jr c,normalize_key_state_after_accept
    call advance_key_repeat_state
    ld a,(hl)
    ld l,81h
    call lookup_de_from_state_phase_table
; -----------------------------------------------------------------------
; Normalize post-acceptance 308Ch states such as 1Ah->18h and 10h->0Eh before committing the board update.
; jumps from 068Eh, 0692h, 0697h
normalize_key_state_after_accept:
    ld l,8Ch
    ld a,(hl)
    cp 1Ah
    jr nz,normalize_key_state_after_accept_tail
    ld (hl),18h
; -----------------------------------------------------------------------
; Continue the 308Ch normalization with the 10h->0Eh reduction.
; jumps from 06A7h
normalize_key_state_after_accept_tail:
    cp 10h
    jr nz,force_ff_before_engine_handoff_if_requested
    ld (hl),0Eh
; -----------------------------------------------------------------------
; If the decoded D byte requests it, force 308Ch back to FFh before handing control to the engine.
; D.bit7 is the explicit handoff/control marker in the tagged transition pair.
; jumps from 06ADh
force_ff_before_engine_handoff_if_requested:
    bit 7,d
    jr z,commit_decoded_update_and_check_request
    ld (hl),FFh
; -----------------------------------------------------------------------
; Commit the decoded board update and raise any immediate CHECK indication.
; jumps from 06B3h
commit_decoded_update_and_check_request:
    ld l,81h
    inc (hl)                                 ; Advance the board-action / phase counter for this accepted board update.
    bit 7,e
    jr z,apply_visible_pair_then_handoff_transition_pair
    set 4,(iy+5)                             ; CHECK LED request (bit 4 of ram_led_select_bits).
; -----------------------------------------------------------------------
; jumps from 06BCh
apply_visible_pair_then_handoff_transition_pair:
    call apply_move_from_ram_pair
    ld a,d
    and 77h
    ld l,a
    ld a,e
    and 77h
    ld h,a
    jr handoff_move_to_engine_and_refresh
; -----------------------------------------------------------------------
; DM key (Double Move). Show the "doub" message and arm the related mode.
; jumps from 05D1h
key_double_move_handler:
    cp BDh                                   ; Compare against KEY_DM (BDh).
    jr nz,key_problem_mode_handler
    res 3,(hl)
    res 4,(hl)
    call clear_ui_state_and_rebuild_display
    set 3,(iy+3)
; -----------------------------------------------------------------------
; jumps from 05FBh
load_doub_message_ptr:
    ld l,F8h                                 ; Load 00F8h -> display message "doub".
; -----------------------------------------------------------------------
; jumps from 070Bh
display_page0_message_and_reset_a:
    call copy4_from_page0_to_display
    sub a
; -----------------------------------------------------------------------
; PB key (Problem mode).
; jumps from 06D1h
key_problem_mode_handler:
    cp DDh                                   ; Compare against KEY_PB (DDh).
    jr nz,apply_key_effect_to_board_state
    bit 1,b
    jp nz,clear_reset_tail
    bit 3,c
    jr nz,trigger_engine_or_problem_action
    set 1,(hl)
    ld a,FFh
    ld (ram_key_state),a
    dec l
    ld a,(hl)
    dec a
    jr nz,show_problem_message
    ld (hl),23h
    sub a
    ld e,a
; -----------------------------------------------------------------------
; Clear the problem-board workspace from 3000h upward.
; jumps from 0703h
clear_problem_workspace_loop:
    ld (de),a
    inc e
    jp p,clear_problem_workspace_loop
; -----------------------------------------------------------------------
; jumps from 06FBh
show_problem_message:
    call clear_ui_state_and_rebuild_display
    ld l,FCh                                 ; Load 00FCh -> display message "Prob".
    jr display_page0_message_and_reset_a
; -----------------------------------------------------------------------
; Trigger the engine/problem action after a command key changed state.
; jumps from 054Bh, 06EFh
trigger_engine_or_problem_action:
    rst 30h
    dec a
    jr z,seed_problem_or_computer_first_handoff
    ld a,FFh
    ld (ram_key_state),a                     ; Key/front-end state forced to FFh.
    exx
    bit 7,c
    jr z,prepare_generic_engine_problem_entry
    res 7,c
    ld d,FFh
    jr unwind_dispatch_frame_before_engine_entry
; -----------------------------------------------------------------------
; Mark the alternate side-to-move path and clear D for the generic engine/problem entry.
; jumps from 0719h
prepare_generic_engine_problem_entry:
    set 7,c
    sub a
    ld d,a
; -----------------------------------------------------------------------
; Unwind the temporary dispatch frame before entering the engine/problem core.
; jumps from 071Fh, 0608h
unwind_dispatch_frame_before_engine_entry:
    pop af
    pop af
; -----------------------------------------------------------------------
; Path taken after CB toggles side/orientation and the engine must refresh its derived state.
; In the opening levels where CB acts as "computer first", this refresh lands with d2-d4 already applied and displayed.
setup_after_cb_toggle:
    call level_setup_banner_and_params
    jp finalize_candidate_window_pointer
; -----------------------------------------------------------------------
; Seed the problem/computer-first handoff path with a randomized 308Ch state and derived orientation bytes.
; The two seeded root offsets are 56h and FEh, which in phases 1..3 line up with the
; ...d5/...e6 and ...e5/...Nc6/...Bc5 development families in the page-02 lattice.
; jumps from 070Fh
seed_problem_or_computer_first_handoff:
    exx
    set 7,c
    ld d,a
    exx
    ld a,r
    ld hl,1333h
    rrca
    ld a,56h
    jr c,store_randomized_key_state_for_handoff
    inc h
    inc l
    ld a,FEh
; -----------------------------------------------------------------------
; Shared store of the newly chosen 308Ch key/front-end state.
; jumps from 073Ah, 0651h
store_randomized_key_state_for_handoff:
    ld (ram_key_state),a
; -----------------------------------------------------------------------
; Final front-end to engine handoff: store the move pair, commit it on the board, then rebuild the visible window.
; jumps from 06CDh
handoff_move_to_engine_and_refresh:
    set 4,(iy+2)                             ; ram_frontend_flags0.bit4 is armed here; this is part of the engine/command handover.
    ld (ram_move_to_square),hl
    call apply_move_from_ram_pair
    jr rebuild_display_after_square_or_handoff_update
; -----------------------------------------------------------------------
; Apply a keypad effect to board/UI state, or interpret one of the A1..H8 square keys.
; jumps from 06E6h
apply_key_effect_to_board_state:
    ld hl,C5h
    ld bc,8                                   ; 00C5h-00CCh hold the diagonal board keys in reverse order H8..A1.
    cpir
    jr nz,return_to_multiplex_loop_after_square_entry
    inc c                                     ; Convert the reverse-order match into a 1..8 selector:
    ld b,c                                    ;   A1=1, B2=2, ... H8=8.
    ld hl,ram_frontend_flags1
    bit 2,(hl)
    jr z,handle_normal_square_entry_path
    dec hl
    bit 1,(hl)
    jr z,refresh_after_square_key_update
    ld a,b
    bit 0,a
    jr z,apply_board_edit_piece_palette
    ld b,0Ah
    dec a
    jr z,apply_board_edit_piece_palette
    cp 2
    jr nz,return_to_multiplex_loop_after_square_entry
    ld b,0Ch
; -----------------------------------------------------------------------
; Board-edit piece-palette path reached from the diagonal square keys.
; jumps from 076Ah, 076Fh
apply_board_edit_piece_palette:
    rrc b
    ld l,84h
    ld e,(hl)                                ; Board-edit path: 3084h points at the currently selected 0x88 square.
    ld a,(de)
    dec a
    ld a,b
    jp p,store_selected_edit_piece_code
    cpl
    inc a
; -----------------------------------------------------------------------
; Store the chosen edit-mode piece code back to the selected square.
; jumps from 077Fh
store_selected_edit_piece_code:
    ld (de),a                                ; Diagonal keys are repurposed here as a 6-piece palette:
                                            ; B2->pawn, D4->knight, F6->bishop, H8->rook, A1->queen, C3->king.
                                            ; The sign comes from the previous square contents (empty/negative -> negative piece, positive -> positive piece).
    jp walk_review_cursor_over_board
; -----------------------------------------------------------------------
; Normal square-entry path once we are not in board-edit mode.
; jumps from 0760h
handle_normal_square_entry_path:
    dec hl
    bit 3,(hl)
    jr nz,refresh_after_square_key_update
    bit 4,(hl)
    jr z,enter_or_continue_square_entry_state
    res 4,(hl)
; -----------------------------------------------------------------------
; Shared refresh tail after a square key changed either the selection window or the board-edit cursor.
; jumps from 0765h, 078Bh
refresh_after_square_key_update:
    res 3,(iy+2)                             ; Clear the scripted/UI refresh latch before rebuilding the visible move window.
    push bc
    call clear_ui_state_and_rebuild_display
    pop bc
; -----------------------------------------------------------------------
; Enter or continue the two-keystroke square-entry state machine for FROM / TO.
; jumps from 078Fh
enter_or_continue_square_entry_state:
    ld l,87h                                  ; Normal move-entry path:
                                              ;   first fill FROM (3087h), then TO (3086h), ignoring extra square keys once both are valid.
                                              ; Each square byte is entered in two diagonal-key presses:
                                              ;   FFh --file--> F0h..F7h  (A1..H8 select file a..h by +1 steps)
                                              ;   Fxh --rank--> 00h..77h  (A1..H8 select rank 1..8 by +10h steps with wrap)
                                              ; For example, E5,B2,E5,D4,EN builds e2-e4.
    ld a,88h
    and (hl)
    jr nz,choose_square_entry_increment
    dec hl
    ld a,88h
    and (hl)
    jr z,return_to_multiplex_loop_after_square_entry
; -----------------------------------------------------------------------
; Decide whether this key press contributes the file nibble (+1 steps) or the rank nibble (+10h steps).
; jumps from 07A1h
choose_square_entry_increment:
    ld c,10h
    bit 3,a
    jr z,load_partial_square_entry_byte
    ld c,1                                    ; First half of a square: seed EFh so repeated +1 steps land on F0h..F7h.
    ld (hl),EFh
; -----------------------------------------------------------------------
; Load the partially built square byte before applying the repeated-add selector.
; jumps from 07ADh
load_partial_square_entry_byte:
    ld a,(hl)
; -----------------------------------------------------------------------
; Apply the repeated-add selector `B` times to turn the chosen diagonal key into a file or rank nibble.
; jumps from 07B5h
apply_square_entry_increment_loop:
    add a,c                                   ; Repeated-add selector: +1 chooses the file nibble, +10h chooses the rank nibble.
    djnz apply_square_entry_increment_loop
    ld (hl),a
; -----------------------------------------------------------------------
; Rebuild the display after a square-entry or engine-handoff update.
; jumps from 074Dh
rebuild_display_after_square_or_handoff_update:
    call rebuild_from_to_display
; -----------------------------------------------------------------------
; Shared exit back to the multiplex/debounce loop.
; jumps from 0757h, 0773h, 07A7h
return_to_multiplex_loop_after_square_entry:
    jp exit_refresh_slice_and_resume_scan
; -----------------------------------------------------------------------
; Start the engine side of the move/search sequence.
; jumps from 0059h
start_engine_move_or_search:
    call level_setup_banner_and_params
    exx
    ld l,B7h                                  ; Preload the upper/root-reply record tail so 07FDh writes back to 30B3h-30B7h and leaves L at 30B2h.
    exx
; -----------------------------------------------------------------------
; Make a move on the 0x88 board and update the material accumulator if a capture occurs.
; calls from 0BADh; jumps from 004Ch, 0993h
make_move_and_update_material:
    ld b,l
    ld l,e
    ld a,c
    ex af,af'
    ld c,(hl)
    sub a
    ld (hl),a
    ld l,b
    add a,(hl)
    jr z,prepare_quiet_move_threaded_record
    call lookup_piece_property
    rst 8
    ld a,(hl)
    add a,d
    xor d
    rst 20h
    ld b,a
    rrca
    rrca
    xor b
; -----------------------------------------------------------------------
; Quiet-move / non-capture tail before the threaded move record is written back.
; jumps from 07CEh
prepare_quiet_move_threaded_record:
    ld b,a
    ld a,c
    inc a
    cp 3
    ld a,c
    jr nc,commit_move_and_write_threaded_record
    xor l
    cpl
    and 70h
    ld a,c
    jr nz,commit_move_and_write_threaded_record
    ld a,8
    add a,d
    xor d
    rst 8
    exx
    pop de
    ld a,e
    cp 5Fh
    jr nz,normalize_threaded_return_tag
    dec e
; -----------------------------------------------------------------------
; Normalize the caller-return low byte when the special 5Fh continuation tag would collide with the trampoline tail.
; jumps from 07F5h
normalize_threaded_return_tag:
    push de
    exx
    ld a,c
    xor 4
; -----------------------------------------------------------------------
; Write the compact 6-byte threaded move record backwards from the preseeded tail.
; jumps from 07E2h, 07E9h
commit_move_and_write_threaded_record:
    ld (hl),a                                  ; Commit the moving piece to the destination board square in the main 0x88 board.
    ld a,b
    and 8
    add a,e                                    ; Build the tagged FROM byte in I: base 0x88 square plus any tag carried in B bit3.
                                                ; For an ordinary quiet move, B is still 00h here, so the record keeps the plain 0x88 FROM square.
    ld i,a
    ld a,b
    rlca
    and 88h
    add a,l                                    ; Build the tagged TO byte: base 0x88 square plus tag bits in the masked-off 0x88 positions.
                                                ; For an ordinary quiet move, this likewise stays as the plain 0x88 TO square.
    exx
    pop de                                    ; The low byte of the caller's return address becomes the threaded continuation tag; the record is written backwards from the seeded tail.
    ld (hl),e
    dec l
    ex de,hl
    ld hl,(ram_disp_to_lo)
    ex de,hl
    ld (hl),d
    dec l
    ld (hl),e
    dec l
    ld (hl),a
    dec l
    ld a,i
    ld (hl),a
    dec l
    exx
    ld a,c
    add a,d
    xor d
    cp FAh
    jr nz,handle_opposite_color_special_cleanup
    ld a,l
    xor e
    and 71h
    jr z,relocate_castling_companion_square
    exx
    ex de,hl
    ld hl,5
    add hl,de
    ld a,(hl)
    cp 5Fh
    jr nz,finish_king_special_case_tag_adjustment
    inc (hl)
; -----------------------------------------------------------------------
; Finish the king-special-case tag adjustment after incrementing the threaded continuation byte.
; jumps from 0833h
finish_king_special_case_tag_adjustment:
    ex de,hl
    exx
    jr rejoin_after_move_commit_special_case
; -----------------------------------------------------------------------
; Same-file king castling-style path: relocate the rook-side square/tag companion bytes.
; jumps from 0828h
relocate_castling_companion_square:
    ld b,l
    inc l
    bit 2,l
    jr z,write_castling_companion_tag_and_square
    dec l
    dec l
; -----------------------------------------------------------------------
; jumps from 083Eh
write_castling_companion_tag_and_square:
    ld a,FCh
    add a,d
    xor d
    ld (hl),a
    ld a,F0h
    and b
    bit 2,b
    jr z,clear_selected_aux_square
    or 7
    jr clear_selected_aux_square
; -----------------------------------------------------------------------
; Opposite-colour/special-piece cleanup path that may decrement the threaded continuation byte.
; jumps from 0822h
handle_opposite_color_special_cleanup:
    xor FFh
    add a,b
    jr nz,rejoin_after_move_commit_special_case
    ld a,e
    xor l
    and 0Fh
    jr z,rejoin_after_move_commit_special_case
    ld a,c
    cpl
    inc a
    rst 8
    exx
    ex de,hl
    ld hl,5
    add hl,de
    ld a,(hl)
    cp 5Fh
    jr nz,finish_special_cleanup_and_choose_aux_square
    dec (hl)
; -----------------------------------------------------------------------
; Finish the special cleanup path and compute the auxiliary square to be cleared.
; jumps from 086Ah
finish_special_cleanup_and_choose_aux_square:
    ex de,hl
    exx
    ld a,c
    rst 20h
    cpl
    inc a
    add a,l
; -----------------------------------------------------------------------
; Clear the auxiliary square selected by the previous special-move logic.
; jumps from 084Ch, 0850h
clear_selected_aux_square:
    ld l,a
    ld (hl),0
; -----------------------------------------------------------------------
; Rejoin the search-status path after the move-commit/special-move bookkeeping.
; jumps from 0838h, 0855h, 085Bh
rejoin_after_move_commit_special_case:
    ex af,af'
    ld c,a
    bit 6,c
    jr nz,finalize_candidate_window_pointer
    bit 4,c
    jp nz,refresh_castling_disable_bits
; -----------------------------------------------------------------------
; Normalize the score/window sign, store the candidate pointer, and advance the route mask.
; jumps from 072Ah, 087Bh
finalize_candidate_window_pointer:
    ld a,d
    cpl
    ld d,a
    xor c
    exx
    ld de,32C8h
    jp m,store_current_candidate_window_even_if_inverted
    rst 10h
; -----------------------------------------------------------------------
; Store the current candidate window pointer / score word at 308Ah even when the previous comparison came in inverted.
; jumps from 088Ah
store_current_candidate_window_even_if_inverted:
    ex de,hl
    ld (ram_disp_to_lo),hl                   ; Store the current candidate window pointer / score word at 308Ah.
    ex de,hl
    exx
    rlc (iy+11h)
; -----------------------------------------------------------------------
; Clear the 64-byte sidecar map in the 0x88 holes before the next evaluation/search pass.
; jumps from 062Bh
clear_sidecar_map_and_begin_search:
    set 5,c
    ld l,8
    sub a
    ; Zero the 64-byte per-square sidecar map stored in the 0x88 holes (3008h-300Fh, 3018h-301Fh, ...).
; -----------------------------------------------------------------------
; Sidecar-hole clear loop.
; jumps from 08A1h
clear_sidecar_hole_loop:
    ld (hl),a
    inc l
    set 3,l
    jp p,clear_sidecar_hole_loop
; -----------------------------------------------------------------------
; Reset A and resume the generic square search / queue helper from the current scan position.
; calls from 0CB0h; jumps from 0C6Ah, 0169h
resume_search_from_current_square:
    sub a
    jp search_or_queue_square
; -----------------------------------------------------------------------
; Scan the board for the next candidate piece/square matching the current search criteria.
; jumps from 00AFh, 08CDh, 0C12h
scan_board_for_candidate_piece:
    ld e,a
; -----------------------------------------------------------------------
; Probe the current board square and decide whether it matches the active search colour/class filter.
; jumps from 08CAh
probe_current_square_against_search_filter:
    ld l,e
    ld a,(hl)
    or a
    jr z,advance_board_scan_to_next_square
    bit 5,c
    jr nz,cache_matching_piece_and_script_selector
    xor d
    ld a,(hl)
    jp p,advance_board_scan_to_next_square
; -----------------------------------------------------------------------
; Matching square found: cache the piece code and push the per-piece script selector.
; jumps from 08B0h
cache_matching_piece_and_script_selector:
    ld (ram_piece_or_square_tmp),a           ; Remember the piece code found during the scan.
    add a,EDh
    call lookup_page0_byte
    exx
    ld d,1
    ld e,a
    push de
    exx
    ret
; -----------------------------------------------------------------------
; Step E to the next legal 0x88 square during board scan.
; jumps from 08ACh, 08B4h
advance_board_scan_to_next_square:
    inc e
    ld a,e
    and 8
    jr z,probe_current_square_against_search_filter
    add a,e
    jp p,scan_board_for_candidate_piece
; -----------------------------------------------------------------------
; Core search driver / move-selection entry.
search_driver:
    ld a,(ram_search_stage_cursor)
    ld b,a
    bit 5,c
    jr z,search_staged_branch_window
    res 5,c
    bit 6,c
    jr nz,enter_candidate_evaluator_from_threaded_path
    and (iy+10h)                               ; Test the current stage against ram_stage_route_mask (3090h).
    jr z,test_stage_mask_for_piece_branching
; -----------------------------------------------------------------------
; Threaded/route-mask path: normalize the record pointer and jump straight into the candidate evaluator.
; jumps from 08DCh
enter_candidate_evaluator_from_threaded_path:
    call normalize_window_and_board_pointer
    jp evaluate_candidate_and_compare_window
; -----------------------------------------------------------------------
; Generic staged-search path: test whether the current stage mask still allows piece-based branching.
; jumps from 08E1h
test_stage_mask_for_piece_branching:
    ld a,(ram_schedule_stage_mask)
    and b
; -----------------------------------------------------------------------
; Threaded-record replay gate: ignore trampoline bytes 5Eh/5Fh/60h and otherwise materialize the tagged FROM/TO pair.
; jumps from 08FBh, 08FEh, 0901h
replay_threaded_record_gate:
    jp z,search_branch_when_piece_present
    exx
    ld c,l
    ld a,l
    add a,5
    ld l,a                                    ; Byte +5 of the current threaded record: continuation / dispatch tag.
    ld a,(hl)
    ld l,c
    exx
    sub 5Eh                                   ; 5Eh/5Fh/60h are the 015Eh-0160h trampoline tail bytes: they route back to the generic search branch instead of the threaded early path.
    jr z,replay_threaded_record_gate
    dec a
    jr z,replay_threaded_record_gate
    dec a
    jr z,replay_threaded_record_gate
    set 4,c                                     ; Local search flag: this candidate came from a threaded early-game record replay.
    call normalize_window_and_board_pointer
    call decode_stage_record_window
    ld b,a
    inc l
    ld a,(hl)
    and 77h
    ld (de),a
    dec e
    inc l
    ld a,(hl)
    and 77h
    ld (de),a
    ld hl,(ram_disp_from_lo)
    ex de,hl
    exx
    ld a,d
    xor c
    exx
    jp m,compare_materialized_threaded_candidate
    rst 10h
; -----------------------------------------------------------------------
; Finish the threaded-record materialization path and compare the resulting candidate record against the current window.
; jumps from 091Fh
compare_materialized_threaded_candidate:
    dec l
    ld (hl),d
    dec l
    ld (hl),e
    push hl
    pop ix
    ex de,hl
    call compare_move_record_keys_at_ix
    ex af,af'
    ld l,a
    ld h,30h
    jp resume_candidate_evaluator_exx
; -----------------------------------------------------------------------
; Pure staged-search path when bit5 of C is clear.
; jumps from 08D6h
search_staged_branch_window:
    bit 6,c
    ret nz
    ld a,b
    rlca
    and (iy+0Fh)
    jp z,normalize_display_pointer_before_post_search
    ld (ram_search_stage_cursor),a           ; Temporarily replace the stage cursor while exploring a branch.
    call decode_stage_record_window
    rrc (iy+11h)
    dec c
    dec c
    dec c
    dec c
    ld l,e
    add hl,bc
    srl c
    inc l
    inc l
    ld e,l
; -----------------------------------------------------------------------
; Move the trailing half of the staged record window down by one entry to make room for replay/speculative insertion.
; jumps from 095Bh
shift_staged_window_tail_down_loop:
    dec l
    dec l
    ldd
    ldd
    jp pe,shift_staged_window_tail_down_loop
    add a,a
    add a,4
    ld b,a
    ld a,B9h
; -----------------------------------------------------------------------
; Refill the vacated tail of the staged window with the B9h sentinel byte.
; jumps from 0966h
refill_shifted_window_tail_with_sentinel:
    ld (de),a
    dec e
    djnz refill_shifted_window_tail_with_sentinel
    ex af,af'
    ld l,a
    exx
    rlc (iy+11h)
    call decode_stage_record_window
    rrc (iy+11h)
    ld l,e
    add hl,bc
    ld a,(hl)
    cp B9h
    jr z,restore_saved_window_selector_after_empty_slot
    exx
    ld e,a
    exx
    dec l
    ld a,(hl)
    exx
    ld l,a
    exx
    ld e,l
    inc e
    dec l
    srl c
    lddr
    ld de,015Fh                                ; Synthetic return trampoline: 015Fh = NOP, 0160h = JP 096Bh.
    push de
    ex af,af'
    ld l,a
    exx
    jp make_move_and_update_material           ; Replay the threaded record as a speculative move through the normal make-move path.
; -----------------------------------------------------------------------
; Store a candidate move and refresh the window/display pointers.
; jumps from 01F2h
store_candidate_and_update_display:
    exx
    push hl
    ld de,6
    add hl,de
    ld e,d
    bit 7,(hl)
    jr z,merge_candidate_pointer_delta_into_display_base
    ld a,(ram_search_stage_cursor)
    ld e,a
; -----------------------------------------------------------------------
; Merge the candidate pointer delta into the current display/window base before publishing it.
; jumps from 099Fh
merge_candidate_pointer_delta_into_display_base:
    ld hl,(ram_disp_to_lo)
    bit 7,h
    jr nz,store_adjusted_display_window_pointer
    rst 10h
; -----------------------------------------------------------------------
; Store the adjusted display/window pointer back into 3088h/3089h.
; jumps from 09AAh
store_adjusted_display_window_pointer:
    add hl,de
    ex de,hl
    rst 10h
    ex de,hl
    ld (ram_disp_from_lo),hl
    pop hl
    pop af
    jr resume_candidate_evaluator_exx
; -----------------------------------------------------------------------
; Restore the saved low-byte window selector after a B9h/empty-slot fast path.
; jumps from 097Bh
restore_saved_window_selector_after_empty_slot:
    ex af,af'
    ld l,a
    exx
; -----------------------------------------------------------------------
; No staged branch selected: normalize the display/window pointer and fall through to the post-search bookkeeping.
; jumps from 093Dh
normalize_display_pointer_before_post_search:
    exx
    push hl
    ld hl,(ram_disp_to_lo)
    ex de,hl
    ld hl,32C8h
    and a
    adc hl,de
    jr z,store_wrapped_pointer_base_into_display_slot
    ld hl,CD38h
    and a
    adc hl,de
    jr nz,finish_no_stage_path_after_pointer_normalization
; -----------------------------------------------------------------------
; Wrapped-pointer case: store the adjusted base back into 3088h/3089h.
; jumps from 09C7h
store_wrapped_pointer_base_into_display_slot:
    rst 10h
    ex de,hl
    ld (ram_disp_to_lo),hl
; -----------------------------------------------------------------------
; Finish the no-stage path and either publish status or continue into the staged best-move logic.
; jumps from 09CFh
finish_no_stage_path_after_pointer_normalization:
    pop hl
    exx
    ld a,(ram_search_stage_cursor)
    rrca
    jp c,post_search_status_update
    rlca
    or a
    jp z,blank_display_digits_before_poll
    exx
    ex de,hl
; -----------------------------------------------------------------------
; Copy the candidate move/window into the display-visible slot and derive the one-hot stage bit used for clearing/publishing.
; jumps from 0B67h
copy_candidate_window_to_display_slot:
    ld hl,(ram_disp_to_lo)                   ; Copy the candidate move/window into the display-visible slot.
    ld (ram_disp_from_lo),hl
    ex de,hl
    ld a,(ram_search_stage_cursor)
    push af
    rlca
    ld b,8
    ld c,a
; -----------------------------------------------------------------------
; Expand the current stage bit into the accumulated mask that selects the window to clear/publish.
; jumps from 09F8h
expand_stage_bit_into_mask_loop:
    sla c
    add a,c
    djnz expand_stage_bit_into_mask_loop
    ld c,a
    ld a,(ram_schedule_stage_mask)
    and c
    jr z,restore_search_stage_cursor_after_window_update
    ld c,80h
; -----------------------------------------------------------------------
; Walk the schedule mask until the chosen one-hot stage bit is isolated in C.
; jumps from 0A06h
isolate_selected_stage_bit_loop:
    rlc c
    rrca
    jr nc,isolate_selected_stage_bit_loop
    ld a,c
    ld (ram_search_stage_cursor),a           ; Replace the stage cursor with a one-hot bit chosen from the current schedule mask.
    call pick_stage_descriptor_pair
    ld a,e
    add a,c
    ld l,a
    ld a,B7h
; -----------------------------------------------------------------------
; Clear the selected staged window from its one-byte upper sentinel down to the fixed guard band at 30B8h.
; jumps from 0A18h
clear_selected_stage_window_loop:
    ld (hl),B9h
    dec l
    cp l
    jr nz,clear_selected_stage_window_loop
    ex af,af'
    ld l,a
; -----------------------------------------------------------------------
; Restore the saved search-stage cursor after clearing/publishing the selected window.
; jumps from 09FFh
restore_search_stage_cursor_after_window_update:
    pop af
    ld (ram_search_stage_cursor),a
; -----------------------------------------------------------------------
; Shared EXX rejoin point before the candidate evaluator runs.
; jumps from 0932h, 09B6h
resume_candidate_evaluator_exx:
    exx
; -----------------------------------------------------------------------
; Candidate evaluator / comparator: decode tagged FROM/TO, apply side effects, then compare against the current best window.
; jumps from 08E6h
evaluate_candidate_and_compare_window:
    ld a,d
    cpl
    ld d,a
    rrc (iy+11h)
    exx
    inc l
    ld a,(hl)
    and 77h
    exx
    ld e,a
    exx
    xor (hl)
    ld c,a
    inc l
    ld a,(hl)
    and 77h
    exx
    ld l,a
    exx
    xor (hl)
    rrca
    add a,c
    ld c,a
    rlca
    rlca
    xor c
    call rst28_extract_high_nibble
    inc l
    ld e,(hl)
    inc l
    ld d,(hl)
    ex de,hl
    ld (ram_disp_to_lo),hl
    ex de,hl
    inc l
    ld e,(hl)
    ld d,1
    push de
    exx
    add a,d
    xor d
    ld b,(hl)
    ld (hl),a
    exx
    ld a,e
    exx
    cp 5Fh
    jr nc,apply_piece_property_penalty_if_occupied
    ld a,b
    xor l
    cpl
    and 70h
    jr nz,handle_empty_aux_square_penalty_path
    ld a,F8h
    add a,d
    xor d
    rst 8
    ld a,4
    xor b
    ld b,a
; -----------------------------------------------------------------------
; Late candidate-evaluator path when the destination square is empty or only needs the file-distance penalty logic.
; jumps from 0A62h
handle_empty_aux_square_penalty_path:
    ld a,(hl)
    or a
    jr nz,apply_lookup_piece_property_penalty
    ld a,e
    xor l
    and 0Fh
    jr z,write_candidate_piece_and_handle_aux_square
    ld a,b
    cpl
    inc a
    rst 20h
    add a,l
    ld l,a
    ld a,b
    cpl
    inc a
    ld (hl),a
; -----------------------------------------------------------------------
; Fast path when the auxiliary square is already occupied/nonzero and the generic piece-property penalty should be applied.
; jumps from 0A5Bh
apply_piece_property_penalty_if_occupied:
    ld a,(hl)
    or a
    jr z,write_candidate_piece_and_handle_aux_square
; -----------------------------------------------------------------------
; Map the encountered piece into the page-0 property byte and fold that penalty into the candidate score.
; jumps from 0A6Fh
apply_lookup_piece_property_penalty:
    call lookup_piece_property
    cpl
    inc a
    rst 8
; -----------------------------------------------------------------------
; Write the candidate piece onto the board, then handle same-file/special-move cleanup before returning to the compare path.
; jumps from 0A75h, 0A83h
write_candidate_piece_and_handle_aux_square:
    ld a,b
    ld (ram_piece_or_square_tmp),a
    ld b,l
    ld l,e
    ld (hl),a
    ld l,b
    add a,5
    cp 0Bh
    jr c,leave_candidate_application_mode
    ld a,e
    xor l
    and 71h
    jr nz,leave_candidate_application_mode
    dec l
    bit 2,l
    jr nz,clear_and_select_aux_square_mirror
    inc l
    inc l
; -----------------------------------------------------------------------
; Select the auxiliary square on the same file/rank that must be cleared or mirrored for special-move cases.
; jumps from 0AA2h
clear_and_select_aux_square_mirror:
    ld a,(hl)
    ld (hl),0
    bit 2,l
    jr z,select_aux_square_opposite_half
    set 0,l
    set 1,l
    jr write_aux_square_and_restore_dest
; -----------------------------------------------------------------------
; Companion branch for the opposite auxiliary-square half.
; jumps from 0AABh
select_aux_square_opposite_half:
    res 0,l
    res 1,l
; -----------------------------------------------------------------------
; Write the auxiliary square update and restore the primary destination pointer.
; jumps from 0AB1h
write_aux_square_and_restore_dest:
    ld (hl),a
    ld l,b
; -----------------------------------------------------------------------
; Leave candidate-application mode and continue into the best-window comparator/publication logic.
; jumps from 0A97h, 0A9Dh
leave_candidate_application_mode:
    res 5,c
    bit 6,c
    jr nz,compare_candidate_window_against_best
    bit 4,c
    res 4,c
    jp nz,return_board_piece_or_zero              ; Threaded replay candidates bypass the generic compare path here after their direct check.
    bit 7,(iy+11h)
    jp nz,skip_scripted_publication_and_unwind
; -----------------------------------------------------------------------
; Compare the current candidate window against the best-so-far window using the signed relation carried in I.
; jumps from 0ABDh
compare_candidate_window_against_best:
    ld a,d
    xor c
    ld i,a
    exx
    push hl
    ld l,91h
    ld b,(hl)                                  ; Current one-hot stage cursor; bit0 later gates publication of the visible best-move pair.
    ld hl,(ram_disp_from_lo)
    ex de,hl
    ld hl,(ram_disp_to_lo)
    ld a,i
    jp m,compare_candidate_window_against_best_inverted
    and a
    sbc hl,de
    jr z,arbitrate_exact_tie_publication
    jp m,store_candidate_as_new_best_window
    jr continue_after_tie_publication_gate
; -----------------------------------------------------------------------
; Same compare path with the relation inverted because the candidate score/window was previously negated.
; jumps from 0ADFh
compare_candidate_window_against_best_inverted:
    and a
    sbc hl,de
    jr z,arbitrate_exact_tie_publication
    jp m,continue_after_tie_publication_gate
; -----------------------------------------------------------------------
; Candidate beats the current best: store the new best window pointer and optionally publish its tagged move pair.
; jumps from 0AE7h
store_candidate_as_new_best_window:
    ex de,hl
    ld (ram_disp_to_lo),hl
    ex de,hl
    bit 0,b
    jr z,secondary_compare_aux_word
; -----------------------------------------------------------------------
; jumps from 0B2Dh
; Copy the tagged move pair out of the selected move record into 3092h/3093h.
; This copy can settle before the move is republished through 3086h/3087h,
; so 3092h/3093h form the earlier tagged-best-move publication path.
publish_tagged_best_move_early:
    ld de,ram_best_move_to_tagged
    pop hl
    push hl
    dec l                                     ; Starting from the stacked record tail, step back to +2 / +1 = tagged TO / tagged FROM.
    dec l
    dec l
    ldd
    ldd
; -----------------------------------------------------------------------
; Flip the blink/status byte to acknowledge that a newly published best move replaced the previous one.
; jumps from 0B31h
acknowledge_best_move_publication:
    ld a,(ram_blink_or_random0)
    cpl
    and 7Fh
    or 40h
    ld (ram_blink_or_random0),a
    call write_ne591_pattern
    ld a,0Fh
    out (0007h),a
; -----------------------------------------------------------------------
; Pop the candidate record pointer and fall into the final compare/publication tail.
; jumps from 0B47h, 0B51h
restore_candidate_record_pointer:
    pop hl
; -----------------------------------------------------------------------
; Final return path once the candidate record pointer has been restored and the current square byte tested.
; jumps from 0B57h
return_if_current_square_nonempty:
    exx
    ld a,(hl)
    or a
    ret
; -----------------------------------------------------------------------
; Exact-tie path: optionally publish the tagged best-move pair depending on the randomized blink/status gate.
; jumps from 0AE5h, 0AEFh
arbitrate_exact_tie_publication:
    bit 0,b
    jr z,continue_after_tie_publication_gate
    ld a,(ram_blink_or_random1)
    ld h,a
    ld a,r
    xor h
    rrca
    rrca
    jr c,publish_tagged_best_move_early
; -----------------------------------------------------------------------
; No publication needed: continue into the secondary compare against the candidate's auxiliary score/pointer bytes.
; jumps from 0AEAh, 0AF1h, 0B22h
continue_after_tie_publication_gate:
    bit 0,b
    jr nz,acknowledge_best_move_publication
; -----------------------------------------------------------------------
; Secondary compare path against the candidate's trailing score/pointer word.
; jumps from 0AFBh
secondary_compare_aux_word:
    pop hl
    push hl
    inc l
    inc l
    inc l
    ld c,(hl)
    inc l
    ld b,(hl)
    ex de,hl
    ld a,i
    jp m,secondary_compare_aux_word_inverted
    and a
    sbc hl,bc
    jp p,enter_secondary_compare_winner_publication
    jr restore_candidate_record_pointer
; -----------------------------------------------------------------------
; Inverted-relation form of the secondary compare.
; jumps from 0B3Eh
secondary_compare_aux_word_inverted:
    and a
    sbc hl,bc
    jr z,resolve_secondary_compare_exact_tie
    jp m,enter_secondary_compare_winner_publication
    jr restore_candidate_record_pointer
; -----------------------------------------------------------------------
; Exact-tie resolution for the secondary compare, including the special-case roots at 30ADh and 30D1h.
; jumps from 0B4Ch
resolve_secondary_compare_exact_tie:
    pop hl
    ld a,l
    cp ADh                                   ; Root record 30ADh falls straight back into the restored-pointer tail.
    jr z,return_if_current_square_nonempty
; -----------------------------------------------------------------------
; Shared winner-publication entry used by the secondary compare.
; The earlier JP targets land on the D1h byte below and execute it as POP DE.
; The tie-resolution fallthrough reaches the preceding EX DE,HL and then consumes FE D1 as CP D1h before
; rejoining the same publication tail. This preserves the original overlapping byte layout at 0B59h-0B5Bh.
; jumps from 0B45h, 0B4Eh
gate_secondary_compare_winner_publication_overlap_prelude:
    ex de,hl
    db 0FEh
enter_secondary_compare_winner_publication:
    pop de                                   ; Shared D1h byte: JP targets enter here, while the fallthrough path reads FE D1 as CP D1h.
    ex de,hl
    exx
    bit 6,c
    jr z,publish_secondary_compare_winner_window
    pop af
    ret
; -----------------------------------------------------------------------
; Candidate won and bit6 of C is clear: publish it through the staged best-move window path.
; jumps from 0B60h
publish_secondary_compare_winner_window:
    exx
    ex de,hl
    pop hl
    jp copy_candidate_window_to_display_slot
; -----------------------------------------------------------------------
; Post-search status update, including CHECK / I LOSE related flags and move-window bookkeeping.
; jumps from 09DCh
post_search_status_update:
    exx
    call beep_if_enabled
    push hl
    ld hl,(ram_disp_to_lo)
    ld de,30D4h
    bit 7,h
    jr nz,check_signed_post_search_loss_threshold
    rst 10h
    add hl,de
    jr nc,load_tagged_best_move_and_maybe_request_check
    jr raise_frontend_status_latch
; -----------------------------------------------------------------------
; Signed-pointer variant of the post-search status check; also raises I LOSE when the candidate window crosses the losing threshold.
; jumps from 0B77h
check_signed_post_search_loss_threshold:
    add hl,de
    jr c,load_tagged_best_move_and_maybe_request_check
    set 5,(iy+5)                             ; I LOSE LED request (bit 5 of ram_led_select_bits).
; -----------------------------------------------------------------------
; Raise the front-end status latch used together with the CHECK/I LOSE LED paths.
; jumps from 0B7Dh
raise_frontend_status_latch:
    set 0,(iy+3)
; -----------------------------------------------------------------------
; Load the currently chosen tagged best-move pair and optionally request CHECK if the FROM byte is tagged.
; jumps from 0B7Bh, 0B80h
load_tagged_best_move_and_maybe_request_check:
    ld hl,ram_best_move_from_tagged
    ld a,(hl)
    bit 7,a
    jr z,publish_best_move_from_tagged_pair
    set 4,(iy+5)                             ; CHECK LED request under another path.
; -----------------------------------------------------------------------
; jumps from 0B90h
; Strip the tag bits from the chosen best-move pair and publish it as FROM/TO in 3087h/3086h.
publish_best_move_from_tagged_pair:
    and 77h
    exx
    ld e,a
    ld (ram_move_from_square),a
    exx
    inc hl
    ld a,(hl)
    pop hl
    exx
    and 77h
    ld (ram_move_to_square),a
    ld (ram_prev_move_to_square),a
    ld l,a
    set 4,c
    call make_move_and_update_material
; -----------------------------------------------------------------------
; Refresh the 4-bit castling-disable cluster after a candidate move has been selected.
; Bit layout in C after this routine:
;   bit0 = white king-side castling unavailable   (h1 rook gone or white king moved)
;   bit1 = white queen-side castling unavailable  (a1 rook gone or white king moved)
;   bit2 = black king-side castling unavailable   (h8 rook gone or black king moved)
;   bit3 = black queen-side castling unavailable  (a8 rook gone or black king moved)
; jumps from 087Fh
refresh_castling_disable_bits:
    res 4,c
    ld a,d
    cpl
    ld d,a
    ld a,(ram_reply_to_tagged)                ; Probe the overlapping upper/reply TO square for king-move castling disable bits.
    call merge_castling_disable_bits_from_king_square
    ld a,(ram_root_to_tagged)                 ; Probe the lower/root TO square as well; the two threaded records straddle the early handoff.
    call merge_castling_disable_bits_from_king_square
    sub a
    ld l,a
    ; Probe corner square 3000h (a1): if empty, white queen-side castling is unavailable.
    cp (hl)
    jr nz,probe_h1_for_castling_disable
    set 1,c
; -----------------------------------------------------------------------
; Probe corner square 3007h (h1): if empty, white king-side castling is unavailable.
; jumps from 0BC4h
probe_h1_for_castling_disable:
    ld l,7
    cp (hl)
    jr nz,probe_a8_for_castling_disable
    set 0,c
; -----------------------------------------------------------------------
; Probe corner square 3070h (a8): if empty, black queen-side castling is unavailable.
; jumps from 0BCBh
probe_a8_for_castling_disable:
    ld l,70h
    cp (hl)
    jr nz,probe_h8_for_castling_disable
    set 3,c
; -----------------------------------------------------------------------
; Probe corner square 3077h (h8): if empty, black king-side castling is unavailable.
; jumps from 0BD2h
probe_h8_for_castling_disable:
    ld l,77h
    cp (hl)
    jr nz,seed_move_confirm_delay_counter
    set 2,c
; -----------------------------------------------------------------------
; Busy-wait setup before the move-confirm beep and display refresh.
; jumps from 0BD9h
seed_move_confirm_delay_counter:
    exx
    ld bc,FFFFh
; -----------------------------------------------------------------------
; Delay loop before beeping and republishing the chosen move.
; jumps from 0BE2h, 0BE4h
move_confirm_delay_loop:
    dec c
    jr nz,move_confirm_delay_loop
    djnz move_confirm_delay_loop
    call beep_if_enabled
    ld hl,ram_phase_turn_counter             ; Advance the board-action / phase counter after the engine-side move commit.
    inc (hl)
    call rebuild_from_to_display
    jr return_to_main_scan_after_scripted_path
; -----------------------------------------------------------------------
; Early exit from the candidate-application path when the threaded replay should skip publication.
; jumps from 0ACAh
skip_scripted_publication_and_unwind:
    pop af
; -----------------------------------------------------------------------
; Blank the four display digits with 40h glyphs before returning to the polling loop.
; jumps from 09E1h
blank_display_digits_before_poll:
    exx
    ld l,88h
    ld b,4
; -----------------------------------------------------------------------
; 4-byte display-blanking loop.
; jumps from 0BFBh
blank_display_digit_loop:
    ld (hl),40h
    inc hl
    djnz blank_display_digit_loop
; -----------------------------------------------------------------------
; Final return to the main scan loop after a scripted/engine-side path.
; jumps from 0BF0h
return_to_main_scan_after_scripted_path:
    ld de,EE05h
    set 3,(iy+2)                             ; ram_frontend_flags0.bit3 is set before re-entering the polling loop from a scripted path.
    jp main_scan_loop
; -----------------------------------------------------------------------
; inline script byte consumed by the engine helper
script_byte_c07:
    db FFh

; -----------------------------------------------------------------------
; Dispatch the current piece into the executable page-01 script family.
; The per-piece selector comes from 00E7h-00F3h: pawns take the special 0100h path,
; while the other classes resolve into the 0176h/0190h/01AAh/01C6h scripts.
; For the king-family path, the low two or high two bits of C act as castling-disable bits
; for the moving side: 00b means both castling sides still available, 11b means neither.
; jumps from 08EDh
search_branch_when_piece_present:
    ld a,c
    bit 0,d
    jr nz,reduce_side_bits_to_piece_script_selector
    rrca
    rrca
; -----------------------------------------------------------------------
; Convert the colour/side bits into the compact 0..3 selector that chooses the page-01 piece-script family.
; jumps from 0C0Bh
reduce_side_bits_to_piece_script_selector:
    cpl
    and 3
    jp z,scan_board_for_candidate_piece
    ex af,af'
    ld a,d
    and 70h
    xor 73h
    ld l,a
    ld a,(hl)
    add a,d
    xor d
    cp FAh
    jr z,seed_piece_script_direction_walk
    inc l
; -----------------------------------------------------------------------
; Seed the per-piece script walk with the first direction delta.
; jumps from 0C21h
seed_piece_script_direction_walk:
    push hl
    ld e,1
    ld b,e
; -----------------------------------------------------------------------
; Walk the compact page-01 piece-script directions, collecting whether 1, 2, or 3 postprocess deltas must be emitted.
; jumps from 0C64h
walk_piece_script_direction_loop:
    pop hl
    push hl
    ld a,3
    ld i,a
    ld a,6
    add a,d
    xor d
    db 0FEh                                  ; Straight-line path reads FE 97 as CP 97h; the wraparound branch below re-enters at the shared 97h byte as SUB A.
restart_piece_script_delta_accumulator:
    sub a
    add a,(hl)
    jr nz,step_to_next_piece_script_delta
    ld a,i
    jr z,advance_to_next_piece_script_direction
    dec a
    ld i,a
    ld a,C0h
    bit 0,d
    jr z,test_current_direction_sidecar_nibble
    ld a,30h
; -----------------------------------------------------------------------
; Test the sidecar occupancy/control nibble associated with the current direction.
; jumps from 0C42h
test_current_direction_sidecar_nibble:
    set 3,l
    and (hl)
    jr nz,step_to_next_piece_script_delta
; -----------------------------------------------------------------------
; Advance to the next direction candidate within the current piece-script family.
; jumps from 0C39h
advance_to_next_piece_script_direction:
    ld a,77h
    and l
    add a,e
    ld l,a
    add a,e
    bit 3,a
    jr z,restart_piece_script_delta_accumulator
    ld a,4
    add a,d
    xor d
    add a,(hl)
    jr nz,step_to_next_piece_script_delta
    ld a,b
    xor e
    ld b,a
; -----------------------------------------------------------------------
; Step to the next signed direction delta and keep track of whether a postprocess scriptlet is still required.
; jumps from 0C35h, 0C49h, 0C5Ah
step_to_next_piece_script_delta:
    dec e
    dec e
    ld a,e
    cp FFh
    jr z,walk_piece_script_direction_loop
    pop hl
    ld e,l
    ex af,af'
    dec b
; -----------------------------------------------------------------------
; Rejoin the generic search helper or dispatch the accumulated 1-3 postprocess deltas.
; jumps from 0C72h
dispatch_pending_piece_script_postprocess:
    jp z,resume_search_from_current_square
    inc b
    jr nz,run_pending_vector_postprocess
    inc b
; -----------------------------------------------------------------------
; If any postprocess deltas remain pending, execute the short scriptlet now.
; jumps from 0C6Eh
run_pending_vector_postprocess:
    and b
    jr z,dispatch_pending_piece_script_postprocess
    jp vector_script_postprocess
; -----------------------------------------------------------------------
; Compressed per-level search-stage descriptors used after LV / engine-side setup.
; 0427h copies 4 overlapping bytes from 0C73h + 3*level into 308Dh-3090h.
; Persistent bytes actually loaded into 308Eh-3090h for levels 1..7 are:
;   CL1=00 00 02  CL2=8C 02 04  CL3=8C 06 08  CL4=00 00 08
;   CL5=8C 10 20  CL6=8C 06 10  CL7=8C 0E 10
; The active pair list rooted at 0C8Ch resolves to nested windows in the same page-30 pool:
;   0C8C = BB 0A -> 30BBh-30E2h (10 sortable 4-byte records), with 30E3h as the upper sentinel byte
;   0C8E = BB 05 -> 30BBh-30CEh (5-record prefix of the same pool), with 30CFh as the upper sentinel byte
;   0C90 = BD 02 -> 30BDh-30C4h (2-record inner window), with 30C5h as the upper sentinel byte
; CL2 and CL5 use only the 10-record window; CL3 and CL6 add the 5-record prefix as a second stage;
; CL7 adds the 2-record inner window as a third stage. CL1 and CL4 leave 308Fh at 00h and only contribute route bits.
; 09E6h-0A18h clears the selected window from its upper sentinel down to 30B8h,
; so 30B8h-30BAh act as the fixed guard/header band in front of the shared record pool.
; In practice, 308Eh-3090h are the persistent stage-schedule bytes:
;   308Eh = page-0C pair-table base offset
;   308Fh = active-stage mask
;   3090h = route mask consulted by search_driver
tbl_level_setup:
    db 00h, 00h, 02h, 8Ch, 02h, 04h, 8Ch, 06h, 08h, 00h, 00h, 08h, 8Ch, 10h, 20h, 8Ch
    db 06h, 10h, 8Ch, 0Eh, 10h, BBh, 0Ah, BBh, 05h, BDh, 02h, 00h, 00h, 02h, 06h, 20h
    db 80h

; -----------------------------------------------------------------------
; Validate the threaded record's tagged FROM/TO bytes against the 0x88 board and, if either leaves range,
; refresh the display/search window state before re-entering the evaluation sweep.
; calls from 08E3h, 0905h
normalize_window_and_board_pointer:
    bit 6,c
    jr nz,seed_pre_eval_accumulators
    exx
    inc l
    ld a,(hl)
    ex af,af'
    inc l
    ld a,(hl)
    dec l
    dec l
    exx
    and 88h
    jr nz,rebuild_window_state_after_oob_tagged_square
    ex af,af'
    and 88h
    jr z,seed_pre_eval_accumulators
; -----------------------------------------------------------------------
; One of the tagged FROM/TO bytes left the 0x88 board: rebuild the search/display pointer state before continuing.
; jumps from 0CA7h
rebuild_window_state_after_oob_tagged_square:
    set 6,c
    call resume_search_from_current_square
    res 6,c
    ld hl,(ram_disp_to_lo)
    ld (ram_disp_from_lo),hl
    ld h,30h
    ret
; -----------------------------------------------------------------------
; Valid tagged record path: clear the temporary accumulators before entering the pre-evaluation sweep.
; jumps from 0C9Ah, 0CACh
seed_pre_eval_accumulators:
    exx
    push hl
    exx
    sub a
    push af
    exx
    ld c,a
    ld d,a
    ld e,a
    exx
    ld l,a
; -----------------------------------------------------------------------
; jumps from 0D43h
; Pre-evaluation sweep over occupied squares.
; The sidecar byte in the matching 0x88 hole is interpreted as:
;   bits7-6 = positive-side control count
;   bits5-4 = negative-side control count
;   bits3-2 = positive-side least-valuable-attacker class
;   bits1-0 = negative-side least-valuable-attacker class
sidecar_pre_eval_square_loop:
    set 3,l
    ld e,(hl)
    res 3,l
    ld a,e
    rst 28h
    and 3
    ex af,af'
    ld a,e
    rlca
    rlca
    and 3
    ld b,a
    ex af,af'
    sub b
    exx
    ld h,a
    rst 30h
    cp 26h                                   ; 26h is a second, slightly later early-game cutoff used by the development/home-square bias.
    ld a,h
    jr nc,continue_sidecar_pre_eval_after_home_bias
    exx
    call lookup_initial_square_nibble
    exx
    ld b,a
    sub a
; -----------------------------------------------------------------------
; Repeat the early-phase home/development bias `B` times and accumulate it into the coarse sidecar score.
; jumps from 0CEBh
accumulate_home_square_bias_loop:
    add a,h
    djnz accumulate_home_square_bias_loop
; -----------------------------------------------------------------------
; Continue the pre-evaluation sweep with the blended sidecar/home-square bias now folded in.
; jumps from 0CE1h
continue_sidecar_pre_eval_after_home_bias:
    exx
    ld b,a
    pop af
    add a,b
    push af
    ld a,(hl)
    or a
    jr z,finalize_square_pre_eval_and_advance
    ld a,e
    rst 28h
    exx
    ld hl,tbl_sidecar_eval_dispatch_root      ; Root of the compact control/exchange dispatch keyed by sidecar high nibble = (positive_count<<2)|negative_count.
    add a,l
    ld l,a
    ld a,(hl)
    exx
    add a,e
    exx
    jp p,resolve_sidecar_threshold_against_piece
    rst 28h
    inc a
; -----------------------------------------------------------------------
; Resolve the compact sidecar dispatch into the packed nibble-pair outcome byte for this square.
; Its high nibble is used when the occupied square holds a negative-side piece, and its low nibble when the square holds a positive-side piece.
; The chosen nibble is then compared against the absolute piece value:
;   selected_threshold - abs(piece_value)
; Only negative deficits survive, and those deficits feed the positive/negative extrema tracked for the coarse tactical score.
; jumps from 0D02h
resolve_sidecar_threshold_against_piece:
    add a,l
    ld l,a
    ld b,(hl)
    exx
    ld a,(hl)
    call lookup_piece_property
    ld b,a
    cpl
    or a
    jp p,fold_tactical_deficit_into_extrema
    inc a
    ld b,a
    exx
    ld a,b
    rst 20h
    ld b,a
    exx
; -----------------------------------------------------------------------
; Fold the dispatch-derived penalty/bonus into the running positive/negative extrema.
; jumps from 0D12h
fold_tactical_deficit_into_extrema:
    exx
    ld a,b
    rst 28h
    exx
    add a,b
    jp p,finalize_square_pre_eval_and_advance
    cpl
    inc a
    ld b,a
    ld a,(hl)
    xor d
    ld a,b
    exx
    jp m,update_negative_primary_extremum
    cp c
    jr c,resume_after_extrema_update
    ld c,a
    jr resume_after_extrema_update
; -----------------------------------------------------------------------
; Negative-side extrema update.
; jumps from 0D2Bh
update_negative_primary_extremum:
    cp d
    jr c,update_negative_secondary_extremum
    ld e,d
    ld d,a
    jr resume_after_extrema_update
; -----------------------------------------------------------------------
; Secondary negative-side extrema update.
; jumps from 0D35h
update_negative_secondary_extremum:
    cp e
    jr c,resume_after_extrema_update
    ld e,a
; -----------------------------------------------------------------------
; Rejoin the board sweep after the sidecar-derived extrema update.
; jumps from 0D2Fh, 0D32h, 0D39h, 0D3Ch
resume_after_extrema_update:
    exx
; -----------------------------------------------------------------------
; jumps from 0CF4h, 0D21h
finalize_square_pre_eval_and_advance:
    call next_square_0x88
    jp p,sidecar_pre_eval_square_loop
    exx
    ld a,c
    add a,a
    sub e
    exx
    ld b,a
    ld a,d
    xor c
    ld a,b
    jp p,convert_extrema_difference_to_signed_base_score
    cpl
    inc a
; -----------------------------------------------------------------------
; Convert the accumulated extrema difference into the signed base score that is later combined with material.
; jumps from 0D4Fh
convert_extrema_difference_to_signed_base_score:
    exx
    ld h,0
    ld l,a
    ld a,(ram_board_cursor_or_material)      ; Material balance is folded into the evaluation here; 3084h is repurposed as a board cursor outside engine search.
    add a,a
    exx
    bit 7,c
    exx
    jr z,finish_signed_score_and_scale
    cpl
    inc a
; -----------------------------------------------------------------------
; Final sign-fix before scaling the score word into the 16-bit evaluation accumulator.
; jumps from 0D60h
finish_signed_score_and_scale:
    add a,l
    ld l,a
    rlca
    jr nc,scale_signed_score_into_eval_word
    dec h
; -----------------------------------------------------------------------
; Scale the signed 8-bit score into the 16-bit word stored at 3088h/3089h.
; jumps from 0D67h
scale_signed_score_into_eval_word:
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld (ram_disp_from_lo),hl
; -----------------------------------------------------------------------
; Evaluation sweep over the full 0x88 board.
; It combines material, sidecar-derived geometry, a king-distance table, and move-history penalties.
board_evaluation_sweep:
    ld hl,ram_board_0x88
    pop af
    ex af,af'
; -----------------------------------------------------------------------
; Per-square evaluation loop over the live 0x88 board.
; jumps from 0E29h
board_eval_square_loop:
    ld a,(hl)
    or a
    jp z,advance_board_eval_and_apply_global_adjustments
    bit 7,a
    jr z,evaluate_pawn_square_path
    cpl
    inc a
; -----------------------------------------------------------------------
; Pawn-specific evaluation path: file/rank table lookup, home-rank tests, and special offsets.
; jumps from 0D7Eh
evaluate_pawn_square_path:
    dec a
    jr nz,evaluate_non_pawn_piece_square_path
    ld a,(hl)
    xor l
    call rst28_extract_high_nibble
    add a,91h
    ld c,a
    ld b,0Ch
    ld a,(bc)
    ld e,a
    ld d,0
    exx
    ld a,c
    exx
    xor (hl)
    jp m,accumulate_pawn_table_delta_and_check_special_square
    rst 10h
; -----------------------------------------------------------------------
; Accumulate the pawn table delta, then test the specially weighted rank/file signature.
; jumps from 0D97h
accumulate_pawn_table_delta_and_check_special_square:
    push hl
    ld hl,(ram_disp_from_lo)
    add hl,de
    ld (ram_disp_from_lo),hl
    pop hl
    ld a,(hl)
    add a,a
    add a,a
    add a,a
    and 70h
    xor l
    sub 13h
    jr z,load_special_pawn_square_bonus
    dec a
    jp nz,advance_board_eval_and_apply_global_adjustments
; -----------------------------------------------------------------------
; Pawn remained on or near a specially weighted square; load the corresponding base bonus/penalty.
; jumps from 0DADh
load_special_pawn_square_bonus:
    ld b,F3h
; -----------------------------------------------------------------------
; Apply the currently selected pawn bonus/penalty with colour sign correction.
; jumps from 0DCDh, 0DD4h, 0DD8h, 0E23h
apply_signed_piece_square_bonus:
    bit 7,(hl)
    jr nz,accumulate_signed_piece_square_bonus
    ld a,b
    cpl
    inc a
    ld b,a
; -----------------------------------------------------------------------
; Add the signed bonus/penalty into the evaluation accumulator.
; jumps from 0DB7h
accumulate_signed_piece_square_bonus:
    ex af,af'
    add a,b
    ex af,af'
    jp advance_board_eval_and_apply_global_adjustments
; -----------------------------------------------------------------------
; Non-pawn evaluation path after subtracting the pawn classes: covers minors, rooks/queens, and kings.
; jumps from 0D83h
evaluate_non_pawn_piece_square_path:
    sub 3
    jr nc,evaluate_king_square_path
    ld b,F3h
    ld a,(hl)
    xor l
    and 70h
    jr z,apply_signed_piece_square_bonus
    ld b,FAh
    ld a,l
    and 7
    jr z,apply_signed_piece_square_bonus
    sub 7
    jr z,apply_signed_piece_square_bonus
    jr advance_board_eval_and_apply_global_adjustments
; -----------------------------------------------------------------------
; King-specific evaluation path: edge-distance table plus a local neighborhood probe via RST 18h.
; jumps from 0DC5h
evaluate_king_square_path:
    cp 2
    jr nz,advance_board_eval_and_apply_global_adjustments
    rst 30h
    jr c,probe_king_neighborhood_pressure
    push hl
    ld a,l
    and 7
    add a,l
    rra
    ld hl,tbl_king_edge_distance             ; Index into the 64-byte king-edge / square-distance table at 0FC0h.
    add a,l
    ld l,a
    ld a,(hl)
    pop hl
    bit 7,(hl)
    jr z,accumulate_king_edge_distance_bonus
    cpl
    inc a
; -----------------------------------------------------------------------
; Fold the king-edge-distance value into the signed evaluation accumulator.
; jumps from 0DF2h
accumulate_king_edge_distance_bonus:
    ld b,a
    ex af,af'
    add a,b
    ex af,af'
; -----------------------------------------------------------------------
; Probe the king neighborhood with fixed relative deltas and choose between the F3h / FAh local-pressure bonuses.
; jumps from 0DE1h
probe_king_neighborhood_pressure:
    ld de,F300h
    ld c,l
    ld b,(hl)
    ld a,10h
    rst 18h                                  ; The following RST 18h calls probe several knight/king/pawn-style offsets.
    ld a,F0h
    rst 18h
    ld d,FAh
    ld a,0Fh
    rst 18h
    ld a,11h
    rst 18h
    ld a,EFh
    rst 18h
    ld a,F1h
    rst 18h
    ld a,FFh
    rst 18h
    ld a,1
    rst 18h
    ld l,c
    ld a,e
    ld b,F3h
    or a
    jr z,apply_king_neighborhood_bonus_if_any
    ld b,FAh
    dec a
; -----------------------------------------------------------------------
; Reuse the common pawn/king bonus application tail after the neighborhood probe chose a result class.
; jumps from 0E1Eh
apply_king_neighborhood_bonus_if_any:
    jp z,apply_signed_piece_square_bonus
; -----------------------------------------------------------------------
; Advance to the next 0x88 square, then apply the global early-phase / repeat-move evaluation adjustments.
; jumps from 0D79h, 0DB0h, 0DC0h, 0DDAh, 0DDEh
advance_board_eval_and_apply_global_adjustments:
    call next_square_0x88
    jp p,board_eval_square_loop
    ex af,af'
    exx
    bit 7,c
    exx
    jr z,apply_global_post_sweep_adjustments
    cpl
    inc a
; -----------------------------------------------------------------------
; Global post-sweep adjustment entry: early-phase descriptor bias, repeated-piece penalty, and final score-word update.
; jumps from 0E31h
apply_global_post_sweep_adjustments:
    ex af,af'
    rst 30h
    jr nc,apply_generic_post_sweep_minus_0d
    ld a,(ram_reply_record_descriptor)        ; Shared boundary byte between the lower/root and upper/reply threaded records; also gates an early-phase eval bias.
    cp 90h
    jr c,skip_generic_minus_0d_unless_descriptor_60
    cp AAh
    jr c,apply_generic_post_sweep_minus_0d
; -----------------------------------------------------------------------
; Special early-phase descriptor range that skips the generic -0Dh adjustment unless the shared descriptor equals 60h.
; jumps from 0E3Eh
skip_generic_minus_0d_unless_descriptor_60:
    cp 60h
    jr nz,apply_repeated_piece_penalty
; -----------------------------------------------------------------------
; Apply the generic post-sweep -0Dh adjustment.
; jumps from 0E37h, 0E42h
apply_generic_post_sweep_minus_0d:
    ex af,af'
    sub 0Dh
    ex af,af'
; -----------------------------------------------------------------------
; Repeated-piece penalty path keyed by the previous TO square and the current root FROM square.
; jumps from 0E46h
apply_repeated_piece_penalty:
    ld a,(ram_root_from_tagged)
    and 77h
    ld b,a
    ld a,(ram_prev_move_to_square)           ; previous TO square: used to penalise immediate re-moves of the same piece
    cp b
    jr nz,widen_final_adjustment_to_eval_delta
    rst 30h
    jr c,apply_early_phase_duplicate_move_penalty
    ex af,af'
    sub 14h
    ex af,af'
; -----------------------------------------------------------------------
; Early-phase duplicate-move penalty; the same -14h adjustment is taken again when the 23h cutoff still holds.
; jumps from 0E59h
apply_early_phase_duplicate_move_penalty:
    ex af,af'
    sub 14h
    ex af,af'
; -----------------------------------------------------------------------
; Convert the final signed 8-bit adjustment into a 16-bit delta and add it to 3088h/3089h.
; jumps from 0E56h
widen_final_adjustment_to_eval_delta:
    ex af,af'
    ld e,a
    ld d,0
    add a,d
    jp p,store_final_eval_word_and_return
    dec d
; -----------------------------------------------------------------------
; Store the final 16-bit evaluation word back into 3088h/3089h.
; jumps from 0E68h
store_final_eval_word_and_return:
    ld hl,(ram_disp_from_lo)
    add hl,de
    ld (ram_disp_from_lo),hl
    pop hl
    exx
    ret
; -----------------------------------------------------------------------
; Step to a relative 0x88 square and test whether it is on-board and acceptable for the current script.
; jumps from 001Ch
step_and_test_0x88_square:
    and 88h
    ret nz
    call edge_bias_from_piece_type
    rst 30h
    jr nc,accept_or_reject_step_square_by_occupancy
    ld a,i
    inc a
    jr z,accept_or_reject_step_square_by_occupancy
    dec a
    dec a
    jr z,accept_or_reject_step_square_by_occupancy
    bit 7,a
    jr nz,accumulate_opposite_colour_step_bias
    bit 7,b
    jr nz,accept_or_reject_step_square_by_occupancy
    ld a,(hl)
    dec a
    jr z,count_successful_step_hit
    ex af,af'
    sub d
    ex af,af'
    jr accept_or_reject_step_square_by_occupancy
; -----------------------------------------------------------------------
; Opposite-colour relative-step path: treat the square as hostile and accumulate the signed edge/home-rank bias accordingly.
; jumps from 0E8Ah
accumulate_opposite_colour_step_bias:
    bit 7,b
    jr z,accept_or_reject_step_square_by_occupancy
    ld a,(hl)
    inc a
    jr z,count_successful_step_hit
    ex af,af'
    add a,d
    ex af,af'
; -----------------------------------------------------------------------
; Shared occupancy/colour accept-reject tail for the relative-step tester.
; jumps from 0E7Dh, 0E82h, 0E86h, 0E8Eh, 0E97h, 0E9Bh
accept_or_reject_step_square_by_occupancy:
    ld a,(hl)
    or a
    ret z
    xor b
    ret m
; -----------------------------------------------------------------------
; Successful relative-step hit: increment E so the caller can count neighboring pressure/coverage.
; jumps from 0E92h, 0E9Fh
count_successful_step_hit:
    inc e
    ret
; -----------------------------------------------------------------------
; Increment L to the next logical square in the 0x88 board, skipping the hole at file 8.
; calls from 0D40h, 0E26h
next_square_0x88:
    inc l
    ld a,l
    and 8
    ret z
    add a,l
    ld l,a
    ret
; -----------------------------------------------------------------------
; Lookup the low nibble from the initial-board template for the square in L.
; Return the lower nibble from the initial-square template for the current 0x88 square.
; Unlike cold start, this helper deliberately ignores the piece nibble and keeps only the per-square class byte
; that the opening/development evaluation reuses before the 26h cutoff.
; calls from 0CE4h
lookup_initial_square_nibble:
    push hl
    ld a,l
    and 77h
    ld l,a
    and 7
    add a,l
    rra
    ld hl,tbl_initial_board_hi_nibbles
    add a,l
    ld l,a
    ld a,(hl)
    pop hl
    and 0Fh
    ret
; -----------------------------------------------------------------------
; Return a small edge/home-rank bias based on the piece and the side-specific control-count field in the sidecar byte.
; calls from 0E79h
edge_bias_from_piece_type:
    set 3,l
    ld a,(hl)
    res 3,l
    bit 7,b
    jr nz,edge_bias_from_piece_type_negative_side
    and 30h
    ret z
    ex af,af'
    add a,3
    ex af,af'
    ret
; -----------------------------------------------------------------------
; Negative-side flavour of the edge/home-rank bias helper.
; jumps from 0ECDh
edge_bias_from_piece_type_negative_side:
    and C0h
    ret z
    ex af,af'
    sub 3
    ex af,af'
    ret
; -----------------------------------------------------------------------
; Run an inline vector/move script through the interpreter at 0EEEh.
; jumps from 00A0h
run_inline_vector_script:
    call vector_script_interpreter
    ret p
    rst 38h
    ld bc,EF10h
    pop af
    ld de,0Fh
    jp advance_to_next_0x88_square_in_e
; -----------------------------------------------------------------------
; Custom vector-script interpreter used by the engine. The script bytes live inline after the call site or in dedicated tables.
; This machinery drives the compact move/attack scripts and the threaded early-game handoff path.
; Any opening/repertoire knowledge present in the ROM is therefore encoded through dense microcode/descriptor bytes,
; not through a flat named-opening line table.
; calls from 0EDFh; jumps from 0F00h
vector_script_interpreter:
    ex (sp),hl
    ld a,(hl)
    inc hl
    ex (sp),hl
    or a
    ret z
    ld b,FFh
    ld i,a
; -----------------------------------------------------------------------
; jumps from 0EFDh
scan_vector_script_until_hit:
    ld a,i
    call test_square_from_script_delta
    jr z,scan_vector_script_until_hit
    ld l,e
    jr vector_script_interpreter
; -----------------------------------------------------------------------
; Test one square reached by a script delta against occupancy, colour, and piece-type conditions.
; calls from 0EFAh
test_square_from_script_delta:
    add a,l
    ld l,a
    and 88h
    ret nz
    ld a,(hl)
    or a
    ret z
    ld a,(ram_piece_or_square_tmp)
    xor (hl)
    jp m,filter_friendly_target_by_piece_class
    bit 7,b
    jr nz,accept_hostile_script_hit_and_store_square
    or a
    ret
; -----------------------------------------------------------------------
; jumps from 0F13h
accept_hostile_script_hit_and_store_square:
    ld b,l
    sub a
    ret
; -----------------------------------------------------------------------
; jumps from 0F0Eh
filter_friendly_target_by_piece_class:
    bit 7,b
    ret nz
    ld a,(hl)
    or a
    jp p,filter_script_target_piece_class
    cpl
    inc a
; -----------------------------------------------------------------------
; jumps from 0F1Fh
filter_script_target_piece_class:
    cp 5
    jr z,reserve_script_slot_if_target_accepted
    cp 4
    jr nz,filter_bishop_like_script_target
    ld a,i
    bit 0,a
    jr z,reserve_script_slot_if_target_accepted
    inc a
    jr z,reserve_script_slot_if_target_accepted
    cp 2
    jr z,reserve_script_slot_if_target_accepted
    ret
; -----------------------------------------------------------------------
; jumps from 0F2Ah
filter_bishop_like_script_target:
    cp 3
    ret nz
    ld a,i
    cp EFh
    jr z,reserve_script_slot_if_target_accepted
    cp F1h
    jr z,reserve_script_slot_if_target_accepted
    cp 11h
    jr z,reserve_script_slot_if_target_accepted
    cp 0Fh
    ret nz
; -----------------------------------------------------------------------
; jumps from 0F26h, 0F30h, 0F33h, 0F37h, 0F41h, 0F45h, 0F49h
reserve_script_slot_if_target_accepted:
    push hl                                  ; Reserve one of four script slots at 30E6h..30F1h.
    ld hl,ram_script_slots
    bit 7,(hl)
    jr nz,write_script_slot_payload
    inc l
    bit 7,(hl)
    jr nz,write_script_slot_payload
    inc l
    bit 7,(hl)
    jr nz,write_script_slot_payload
    inc l
    bit 7,(hl)
    jr z,return_from_script_slot_reservation
; -----------------------------------------------------------------------
; jumps from 0F54h, 0F59h, 0F5Eh
write_script_slot_payload:
    ld (hl),b
    inc l
    inc l
    inc l
    inc l
    inc l
    ld a,i
    ld (hl),a
; -----------------------------------------------------------------------
; jumps from 0F63h
return_from_script_slot_reservation:
    pop hl
    ret nz
    inc a
    ret
; -----------------------------------------------------------------------
; compressed evaluation / distance tables used by the search
tbl_eval_and_distance:
    ; 0F72h-0F79h: FFh prelude bytes; no direct code path currently indexes them.
    ; 0F7Ah-0F89h: active 16-entry root dispatch keyed by sidecar high nibble = (positive_count<<2)|negative_count.
    ;              The root groups the control-count relation before the least-valuable-attacker classes are considered:
    ;                00b/00b -> 99h, 00b/x -> 90h, x/00b -> 09h,
    ;                equal non-zero control -> family 0F90h-0F9Fh,
    ;                negative-side control dominant -> family 0FA0h-0FAFh,
    ;                positive-side control dominant -> family 0FB0h-0FBFh.
    ;              The code adds the full sidecar byte to that root byte:
    ;                if the signed result is non-negative, it directly indexes a terminal/subtable byte;
    ;                otherwise it falls back to ((result >> 4) + 1) as a shared second-stage selector.
    ; 0F8Ah-0F8Fh: shared singleton terminals reached by the sparse-control cases above.
    ; 0F90h-0F9Fh: equal-control nibble pairs; this is the full Cartesian grid of {9,5,3,1} against {9,5,3,1}.
    ; 0FA0h-0FAFh: negative-side-control-dominant nibble pairs; the dominant side starts introducing residual exchange differences {0,2,4,6,8}.
    ; 0FB0h-0FBFh: positive-side-control-dominant nibble pairs; mirror image of the previous family, again with residual differences {0,2,4,6,8}.
    ; The packed bytes are not raw piece codes: each nibble is an exchange/control threshold magnitude.
    ; They include direct piece values (1/3/5/9) and simple exchange differences such as 2,4,6,8.
    ; 0FC0h-0FFFh: 64-byte king-edge / square-distance table used directly by the king-specific evaluation path.
    ; Some high-control sidecar signatures also fall through into terminal bytes in the 0FCDh-0FFAh range.
tbl_sidecar_eval_dispatch:
    db FFh, FFh, FFh, FFh, FFh, FFh, FFh, FFh
tbl_sidecar_eval_dispatch_root:
    ; 0F7Ah-0F89h root: hi nibble = (positive_count<<2)|negative_count.
    db F0h, E0h, C0h, A0h, 90h, C1h, C0h, AFh, 11h, 9Dh, 6Ch, 6Bh, C0h, 59h, 48h, 17h
    ; 0F8Ah-0F8Fh singleton terminals for the sparse-control cases.
tbl_sidecar_eval_singletons:
    db 99h, 90h, 09h, 09h, 09h, 09h
    ; 0F90h-0F9Fh equal-control family: symmetric {9,5,3,1} x {9,5,3,1} attacker-class outcomes.
tbl_sidecar_eval_equal_control:
    db 99h, 95h, 93h, 91h, 59h, 55h, 53h, 51h, 39h, 35h, 33h, 31h, 19h, 15h, 13h, 11h
    ; 0FA0h-0FAFh negative-side-control-dominant family: the advantaged side introduces residual exchange differences 0/2/4/6/8.
tbl_sidecar_eval_negative_control_dominant:
    db 90h, 90h, 90h, 90h, 54h, 50h, 50h, 50h, 36h, 32h, 30h, 30h, 18h, 14h, 12h, 10h
    ; 0FB0h-0FBFh positive-side-control-dominant family: mirror image of the previous family with residual differences 0/2/4/6/8 on the positive side.
tbl_sidecar_eval_positive_control_dominant:
    db 09h, 45h, 63h, 81h, 09h, 05h, 23h, 41h, 09h, 05h, 03h, 21h, 09h, 05h, 03h, 01h
tbl_king_edge_distance:
    db 20h, 16h
    db 09h, 03h, 03h, 09h, 16h, 20h, 16h, 12h, 06h, 00h, 00h, 06h, 12h, 16h, 09h, 06h
    db 06h, 00h, 00h, 06h, 06h, 09h, 03h, 00h, 00h, 00h, 00h, 00h, 00h, 03h, 03h, 00h
    db 00h, 00h, 00h, 00h, 00h, 03h, 09h, 06h, 06h, 00h, 00h, 06h, 06h, 09h, 16h, 12h
    db 06h, 00h, 00h, 06h, 12h, 16h, 20h, 16h, 09h, 03h, 03h, 09h, 16h, 20h
