# Changelog

## [Unreleased]

**Fixed**
- Nested blocks saving the graphics state (`transparent`, `rotate`…) that cross a page break no longer raise
  `EmptyGraphicStateStack` when they end together, where Prawn raises.
- A PNG with an alpha channel whose header announces a width its data never fills renders instead of
  building a per-pixel layout of that width (`ArgumentError: argument too big` on TruffleRuby).
- Fonts with a format 6 or 10 cmap map each character to its glyph as Prawn does, and GPOS kerning reads format 1
  class definitions: the glyph arrays were indexed by a bit of each glyph instead of its position.

## [1.0.0] — 2026-11-04

First release under next-gen-gems: Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 in one gem, rewritten for
speed. Same API and same pages as Prawn, pixel for pixel, in lighter files.

**Breaking**
- PrawnX refuses to load next to the prawn gem; `require "prawn/table"` and `require "prawn-svg"` keep working.
- SVG images fetch nothing from the web unless `enable_web_requests: true`.
- Requires Ruby 3.3 or later, every Ruby still maintained.

**New**
- Opt-in beyond Prawn: OpenType ligatures and GPOS kerning per font, CFF (`.otf`) fonts, PDF/A-3b and Factur-X,
  `PrawnX.eager_load!` before a server forks.
- `PrawnX.combine(sources, page_size:, orientation:)` puts the pages of PDFs written elsewhere in one file, in
  place of combine_pdf.
- `PrawnX::VERSION` is the gem's; `Prawn::VERSION` stays 2.5.0, the API reproduced.

[Unreleased]: https://github.com/next-gen-gems/prawnx/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/next-gen-gems/prawnx/releases/tag/v1.0.0
