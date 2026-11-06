# Changelog

## [Unreleased]

## [2.0.1] — 2026-11-06

Fonts, images, SVGs and PDFs that users send can no longer hang a server, exhaust its memory or crash it.

**Faster**
- Packed indexed transparency in PNGs goes through a byte table: 4 seconds instead of 48 on an 8 KB file.
- Inline formatting tokenizes in linear time and dedupes repeated styles: `"<a" * 40_000` took 5.8 seconds, and `"<b>x" * 8000` used 401 MB.

**Fixed**
- SVG ids are read once instead of through XPath built from the id, which could be injected and scanned the whole document for each missing id. `<use>` cycles are skipped, `<use>` draws at most 20,000 elements, gradient cycles paint nothing, nesting stops at 256 levels, and an SVG's `@font-face` faces no longer replace the application's fonts once it is drawn.
- Composite glyph cycles end, overlapping cmap ranges raise `TrueType::Error`, and malformed name tables or `.otf`/`.ttf` outline mismatches no longer crash. The parsed font cache keeps 64 files.
- Truncated or zero-sized JPEGs raise `FormatError`, and a PNG without a full row is still written.
- An encrypted PDF's `/ID` mixes in the passwords, so it can no longer be used to check guesses at the content, and `owner_password: :random` uses SecureRandom.
- PDF/A metadata with control characters raises `PdfAViolation`, `Gamba.combine` no longer writes NaN for huge reals, and SVG never writes NaN or Infinity.

## [2.0.0] — 2026-11-05

PrawnX is now Gamba, at levups/gamba, and text that overflows onto a page that already exists keeps the state it was drawn with.

**Breaking**
- The gem is named `gamba`: write `gem "gamba"` in your Gemfile in place of `gem "prawnx"`. `require "prawn"`, `require "prawn/table"` and `require "prawn-svg"` keep working.
- The `PrawnX` module is now `Gamba` (`Gamba.combine`, `Gamba.eager_load!`, `Gamba::VERSION`, `Gamba::TrueType::Error`). `Prawn` and `PDF` are unchanged.
- PDFs name `Gamba` as their Creator and Producer, instead of `PrawnX`.

**Fixed**
- Text overflowing onto a page that already exists, after `go_to_page` back to an earlier one, keeps its `transparent` or `blend_mode` block, its colours, line settings and gradient there, as on a new page; Prawn draws it opaque and in that page's own colours.
- After `forget_text_rendering_mode!`, ending a `text_rendering_mode` block or drawing text no longer writes `Tr` without its operand, which Prawn does and which made Poppler drop the text after it.
- A font with no `post` table, or a short one, embeds instead of crashing with `NoMethodError`.

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

[Unreleased]: https://github.com/levups/gamba/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/levups/gamba/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/levups/gamba/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/levups/gamba/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/levups/gamba/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/levups/gamba/releases/tag/v1.0.0
