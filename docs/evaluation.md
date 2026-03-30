# Evaluation

## Purpose

This document explains the scoring pipeline used by the firmware after candidate moves have been materialized.

The source discussed here is the main disassembly in [`chess_challenger_7_rev_b.asm`](../asm/chess_challenger_7_rev_b.asm).

For move generation and staged search, see [`./search_and_move_generation.md`](./search_and_move_generation.md).

## Scope

The evaluator has two broad layers:

- A sidecar-driven pre-evaluation sweep
- A full board sweep with piece-square and king-specific terms

This document follows those two layers and then describes the final global adjustments.

## Evaluation Model

The firmware does not score a candidate with one large formula in one place.

Instead, it accumulates the score through several compact passes:

1. normalize the active record/window state
2. scan the sidecar map for coarse tactical information
3. sweep the live board for piece-square and king terms
4. apply global early-phase and repeated-move adjustments
5. write the final signed word back into `ram_disp_from_lo`

The design is compact, but it is not simplistic. Tactical pressure, development bias, king placement, and short move-history penalties all feed the final score.

## Sidecar Pre-Evaluation

### Sidecar Byte Structure

Each `0x88` hole can store a packed tactical descriptor:

| Bits | Meaning |
| --- | --- |
| `7-6` | positive-side control count |
| `5-4` | negative-side control count |
| `3-2` | positive-side least-valuable-attacker class |
| `1-0` | negative-side least-valuable-attacker class |

The evaluator reads those bytes in `sidecar_pre_eval_square_loop`.

### Early Home-Square Bias

Before consulting the main dispatch table, the pre-evaluation loop checks whether the game is still before the second early-game cutoff at `26h`.

If so, it also looks up the low nibble of the initial board template and repeats that square-class bias `B` times into the coarse score.

This is how the evaluator folds opening-development knowledge directly into the pre-evaluation pass without needing a separate opening-only scoring routine.

### Root Dispatch

The compact dispatch begins at `tbl_sidecar_eval_dispatch_root`.

The root is indexed by the sidecar high nibble:

- `(positive_count << 2) | negative_count`

From there, the firmware chooses among three broad families:

- Sparse singleton cases
- Equal-control cases
- Control-dominant cases for one side or the other

### Threshold Nibble Pairs

The dispatch tables do not store raw piece codes.

The terminal bytes are packed nibble pairs:

- The high nibble is used when the occupied square holds a negative-side piece
- The low nibble is used when the occupied square holds a positive-side piece

The selected nibble is then compared against the absolute piece value:

`selected_threshold - abs(piece_value)`

Only negative deficits survive this comparison, and those deficits are folded into the running positive/negative extrema of the coarse tactical score.

## Control-of-Square Families

The main table families beginning at `0F90h` are:

| Range | Meaning |
| --- | --- |
| `0F90h-0F9Fh` | equal-control outcomes |
| `0FA0h-0FAFh` | negative-side-control dominant outcomes |
| `0FB0h-0FBFh` | positive-side-control dominant outcomes |

Conceptually, the root table classifies the control-count relation first, and only then do the lower bits refine the result by least-valuable-attacker class.

That is why the evaluator remains compact:

- Control counts choose the family
- Attacker classes choose the threshold nibble pair
- The occupied piece decides which nibble is relevant

## Full Board Sweep

After the sidecar pass, the evaluator enters `board_evaluation_sweep`.

This is a full walk over the live `0x88` board. Empty squares are skipped immediately; occupied squares are scored by piece family.

The board sweep combines:

- Signed material-related lookups
- Pawn square effects
- Minor and heavy-piece placement effects
- King-edge and neighborhood pressure

## Pawn Evaluation

Pawns take a special path in `evaluate_pawn_square_path`.

That path uses:

- File/rank-sensitive table lookups
- Home-rank tests
- One specially weighted rank/file signature

The resulting bonus or penalty is then signed according to the piece side and folded into the evaluation accumulator.

This is one of the clearest "piece-square table" style effects in the ROM, even though it is implemented through compact arithmetic and table lookups rather than through a modern named PST array.

## Non-Pawn Piece-Square Effects

Minor pieces, rooks, and queens pass through `evaluate_non_pawn_piece_square_path`.

The logic is simpler than the pawn path, but still position-sensitive:

- Some cases receive the shared `F3h` penalty/bonus class
- Edge and file-sensitive cases can switch to the `FAh` class
- The sign is corrected according to piece colour before the term is accumulated

This produces small but real placement terms for non-pawn pieces without requiring large per-piece tables.

## King Evaluation

Kings take a dedicated path in `evaluate_king_square_path`.

The evaluator uses two king-specific terms.

### King-Edge / Distance Table

The table `tbl_king_edge_distance` at the ROM tail is indexed by a compact transformation of the square.

That value is then signed and folded into the accumulator according to the king side.

This is the cleanest spatial king term in the ROM: a square-to-bonus mapping compressed into one 64-byte table.

### Neighborhood Pressure

The evaluator then probes a fixed set of relative offsets around the king with repeated `RST 18h` calls.

This local probe chooses between the same coarse bonus/penalty classes already used elsewhere:

- `F3h`
- `FAh`

So king safety is not only about edge distance. It also includes a compact local-pressure scan around the king square.

## Global Post-Sweep Adjustments

Once the per-square sweep is complete, the evaluator applies a final layer of global adjustments in `apply_global_post_sweep_adjustments`.

These include:

- An early-phase descriptor-dependent bias keyed by `ram_reply_record_descriptor`
- The generic post-sweep `-0Dh` adjustment
- Repeated-piece penalties keyed by `ram_prev_move_to_square` and `ram_root_from_tagged`

The repeated-piece penalty is especially important because it discourages immediate re-moves of the same piece, and it is applied more strongly while the early `23h` cutoff still holds.

## Final Score Word

The final signed adjustment is widened to a 16-bit delta and added back into the word stored at:

- `ram_disp_from_lo`
- `ram_disp_from_hi`

Those bytes serve double duty:

- Display storage in the front-end
- The active 16-bit score word during engine search

This is another good example of the ROM's style: the evaluator reuses existing RAM bytes rather than allocating a separate named score buffer.

## Summary

The evaluation system is compact but layered:

- The sidecar pass compresses tactical control and exchange information
- The board sweep adds piece-square and king-placement terms
- The final adjustment layer adds early-phase and move-history penalties

The most important structural point is that the evaluator is not a single formula block. It is a pipeline of small scoring passes that reuse:

- The sidecar map
- The live `0x88` board
- The threaded record band
- The shared display/search word bytes
