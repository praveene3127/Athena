# Athena: Brand Guide v3 (black & white)

## 1. The idea
**An owl made from an open book.** Athena's owl of wisdom, drawn as one solid, geometric shape. Its two tufts are the corners of two pages, the notch between them is the spine, and the pupils glance down and inward as if reading. The product keeps every word of the book and adds a companion between the paragraphs, so the owl is the reader and the companion at once.

Construction: a circular chin (radius 100 on a 256 grid) rising into tapered sides and two sharp tufts. Eyes are ring-and-pupil circles, the beak is a small kite. One shape, one colour, no outline.

## 2. Colour: black and white
| Role | Value |
|---|---|
| Ink (logo, text, primary buttons) | `#000000` |
| Paper (backgrounds, reversed logo) | `#FFFFFF` |
| Metadata and hairlines (UI only, never the logo) | `#6B6B6B`, `#F4F4F4` |

The logo is always pure black on white or pure white on black. Contrast 21:1.

## 3. Typography
| Role | Typeface | Weights | Use |
|---|---|---|---|
| Display / logo | **DM Serif Display** | Regular | Wordmark, titles, empty states, onboarding |
| Reading | **Newsreader** | 400, 400 italic, 500, 600 | Book text in Feed/Flow, card bodies, quotes |
| Interface | **Geist** | 400, 500, 600 | Buttons, tabs, labels, metadata, numbers |

All three are open-licence (SIL OFL), licences and WOFF2 files are in `fonts/`. The wordmark is converted to outlines, so it needs no font to display.

Suggested scale (mobile): Display 34/38 · Card title 22/28 Newsreader 600 · Reading text 19/30 Newsreader 400 (the passage size should be adjustable in the `Aa` menu) · UI label 15/20 Geist 500 · Metadata 12/16 Geist 500, +6% tracking, uppercase, `#6B6B6B`.

## 4. Logo files (`logo/`)
| File | Use |
|---|---|
| `athena-horizontal(.svg/-reversed.svg)` | Default lockup: headers, web, documents |
| `athena-stacked(...)` | Square spaces: splash, cover, social |
| `athena-wordmark(...)` | Where the owl already appears nearby |
| `athena-symbol(...)` | Symbol alone, 24 px and up |
| `athena-symbol-small(...)` | **Small-size cut** for 16–24 px: bigger eyes, no beak |
| `png/` | Transparent PNGs at 2400 px (1600 px stacked) |

Reversed (white) files are white on a transparent background: place them on black only.

**Clear space:** the width of one eye ring around every lockup. **Minimum size:** symbol 24 px (use the small cut below that, down to 16 px), horizontal lockup 110 px wide, stacked 70 px wide.

## 5. App icon and favicon (`icons/`)
Primary: white owl on a black tile. Inverse: black owl on a white tile with a black border (needed on white pages). The favicon uses the small cut on a black rounded tile so it holds up in both light and dark browser tabs. The folder includes `favicon.ico`, `favicon.svg`, 16/32/48 PNG, Apple touch icon, 192/512 icons, a maskable icon (80% safe zone), `site.webmanifest` and `head-snippet.html`.

## 6. The avatar (`avatar/`)
The same owl with a face that moves, plus three feather chevrons on the chest. Nine expressions, each in black and white polarity, as SVG, transparent PNG and round profile crop:

| Expression | Suggested use in the app |
|---|---|
| `neutral` | Default, reading along |
| `thinking` | Research running after the user taps Ask |
| `surprised` | A surprising study/paradox card appears |
| `happy` | Saved to vault, finished a chapter |
| `blink` / `sleepy` | Idle, or a long pause with no scrolling |
| `wink` | Playful moments, bet-card reveals |
| `focused` | Focus Mode on |
| `looking` | Pointing attention at a card or source |

`athena-owl-blinking.svg` is a self-contained animated avatar (blink every 4.2 s). Use `neutral` as the profile picture.

## 7. Do not
- Add colour, gradients, shadows or outlines to the logo.
- Redraw or re-set the wordmark in another font, or stretch the owl.
- Use the full owl below 24 px (use the small cut).
- Put the white logo on a light background.
- Add hats, books, glasses or wings to the owl.

## 8. Open items
- **Trademark and reverse-image search before launch.** Owl marks are very common in education and publishing; the open-book idea and the notch silhouette are the distinguishing parts, but this needs a professional check.
- The reversed owl has dark eyes with white pupils (a straight inversion). If you prefer, a hand-drawn reversed eye can be made.
- Avatar animation beyond blinking (expression transitions) needs a small runtime; the SVG parts are separate groups, so it is straightforward to animate in the app.
