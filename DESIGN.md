# Athena — Design System & Brand Identity Direction

> Based on the official brand specifications in `logo/athena-brand-guidelines.md` and `board-spec.json`.
> Direction for anti-slop curation: authentic editorial typography, tactile paper textures, and deliberate restraint.

## 1. Brand Identity & The Mark
- **The Mark**: **Owl A**. A flat-topped geometric `A` with Athena's owl peeking out from inside it: two round eyes and a small beak in the counter.
- **Concept**: A quiet, intelligent companion watching over the page while you read real, full-length non-fiction.
- **Tagline**: *"Read the whole book. Never read alone."*
- **Tone**: Curious, smart, calm, playful. Scholarly yet accessible.

## 2. Core Palette (Strictly Enforced)
| Role | Token | HEX | Description |
| :--- | :--- | :--- | :--- |
| **Canvas** | `canvas` | `#EDF7DB` | Botanical Sage — soothing, low-fatigue background |
| **Surface** | `surface` | `#FCFBF7` | Warm Editorial Paper — tactile book page ground |
| **Ink / Text** | `ink` | `#141714` | Deep Charcoal — crisp, high-contrast readable typography |
| **Brand Accent** | `accent` | `#BAF82A` | Electric Acid Lime — high-impact micro-accent (tiles, active badges) |
| **Secondary Ink** | `inkMuted` | `#4A4F48` | Muted Charcoal — metadata, secondary captions |
| **Border / Rule** | `hairline` | `#D8DEC8` | Botanical Hairline — structural 1px dividers |
| **Verified Accent**| `teal` | `#005E54` | Deep Muted Forest — citations, academic verification |

### Contrast Rules (WCAG Verified)
- Charcoal on sage: `16.3:1`
- Charcoal on paper: `17.4:1`
- Charcoal on lime: `14.2:1`
- Lime on charcoal: `14.2:1`
- **NEVER** place a lime mark on sage, paper, or white (`1.2:1` — invisible). Lime appears ONLY on charcoal, or as the solid background tile behind charcoal ink.

## 3. Anti-Slop Architectural Rules
1. **No Universal Pill-Blobs**:
   - Do NOT turn every card, input, and badge into a pill.
   - Editorial paper cards use crisp, refined radii (`14px` or `16px`).
   - Action buttons use structured functional radii (`8px` or `10px`).
   - The brand tile uses the proportional squircle (`rx=57.6` in a 256 box $\approx 22.5\%$).
2. **No Overly Soft Mushy Shadows**:
   - Surfaces sit grounded on the Botanical Sage canvas with crisp 1px borders (`#D8DEC8`).
   - Elevation is reserved solely for floating modal sheets and bottom navigation HUDs.
3. **No Generic AI Iconography**:
   - Use the official Owl A vector mark for the brand.
   - Use standard, precise editorial iconography (`Icons.arrow_forward_rounded`, `Icons.description_outlined`, `Icons.menu_book_outlined`).
   - Eliminate sparkles (`Icons.auto_awesome`), magic wands, and neon badges.
4. **Honest Copywriting**:
   - Eliminate defensive AI jargon (*"SOURCE FIDELITY: Your Source, Kept Whole"*, *"No AI hallucination"*).
   - Use direct, human book titles, chapter names, and clean editorial archetype labels.
