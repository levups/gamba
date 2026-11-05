# Changelog

## [Unreleased]

## [1.1.0] — 2026-11-05

Page breaks now keep the whole state a page was drawing with, and what is added to a page later no longer inherits
blocks that ended elsewhere.

**Fixed**
- `text_rendering_mode`, `character_spacing`, `word_spacing`, `horizontal_text_scaling` and `rise` blocks whose
  text crosses a page break keep their setting on the next page, where Prawn lays the text out with it but draws
  it without, overflowing the margin.
- A `blend_mode` set without a block, and a fill or stroke gradient, still apply after a page break, where Prawn
  falls back to the Normal blend mode and to the colour set before the gradient.
- Page numbers, repeaters and content drawn again through `go_to_page` on a page a block crossed are drawn outside
  that block once it ended, with the settings in effect before it: since 1.0.1 they came out faded, rotated or
  recoloured on every page a `transparent` or `blend_mode` block crossed (Prawn does it on the first one).

## [1.0.1] — 2026-11-04

Text layout up to 26% faster, page breaks that keep what the page was drawing with, and corrupted fonts and
PNGs refused cleanly instead of crashing.

**Faster**
- Text-heavy documents render 15% faster without JIT and 26% faster with YJIT, with 62% fewer allocations;
  catalogs and invoices 6% faster without JIT and 8% with YJIT (Ruby 4.0, similar on 3.3). Same PDFs, byte for
  byte.

**Fixed**
- A `transparent` or `blend_mode` block whose content crosses a page break keeps its opacity and blend mode on
  the next page, and the colours, line width, dash, cap and join styles set before it still apply once it ends,
  where Prawn draws opaque, in the Normal blend mode, then black with thin solid lines.
- Nested blocks saving the graphics state (`transparent`, `rotate`…) that cross a page break no longer raise
  `EmptyGraphicStateStack` when they end together, where Prawn raises.
- A space is encoded in the font subset of the character before it, as Prawn does: the text operators match
  Prawn's again, and so does the text extracted from the PDF.
- TrueType fonts with a format 6 or 10 cmap map every character to its glyph, as in Prawn, and opt-in GPOS
  kerning reads format 1 class definitions correctly.
- A corrupted font (`unitsPerEm` of zero, a table too short, a truncated glyph) raises
  `Gamba::TrueType::Error` instead of `FloatDomainError`, `ArgumentError` or nil metrics.
- A PNG with an alpha channel no longer takes gigabytes of memory on very wide rows, nor fails with
  `ArgumentError: argument too big` on TruffleRuby when its data fills no row.

## [1.0.0] — 2026-11-04

First release by Level UP Solutions: Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 in one gem, rewritten for
speed. Same API and same pages as Prawn, pixel for pixel, in lighter files.

**Breaking**
- Gamba refuses to load next to the prawn gem; `require "prawn/table"` and `require "prawn-svg"` keep working.
- SVG images fetch nothing from the web unless `enable_web_requests: true`.
- Requires Ruby 3.3 or later, every Ruby still maintained.

**New**
- Opt-in beyond Prawn: OpenType ligatures and GPOS kerning per font, CFF (`.otf`) fonts, PDF/A-3b and Factur-X,
  `Gamba.eager_load!` before a server forks.
- `Gamba.combine(sources, page_size:, orientation:)` puts the pages of PDFs written elsewhere in one file, in
  place of combine_pdf.
- `Gamba::VERSION` is the gem's; `Prawn::VERSION` stays 2.5.0, the API reproduced.

[Unreleased]: https://github.com/levups/gamba/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/levups/gamba/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/levups/gamba/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/levups/gamba/releases/tag/v1.0.0
