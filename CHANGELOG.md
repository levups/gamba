# Changelog

## [Unreleased]

## [2.1.0] — 2026-11-21

Gamba gets an API of its own next to Prawn's, `Gamba.document`: layout described in boxes instead of computed, tables with named columns, barcodes, PDF templates, Rails rendering, test assertions and tagged PDF/UA.

**Breaking**
- `pdf_a:` accepts only `true`, `false`, `nil`, `:a` and `:b`, and raises `ArgumentError` on anything else instead of ignoring it.

**New**
- `Gamba.document` builds a document with an explicit receiver (no `instance_eval`), named styles, and options checked against typos; `gamba { |document| ... }` opens it inside existing Prawn code, and `document.prawn` reaches Prawn's API from it.
- Layout in boxes: `stack`, `row` and `grid(columns:)`, with `gap`, `padding`, `background` and borders; pages break between children and inside paragraphs and tables, decorated stacks included, which draw their frame on each page.
- Typesetter page breaks: `widows` and `orphans` (2 lines each by default) and `keep_with_next`, usable in named styles; `page_break` starts a new page.
- `header` and `footer` built for each page with its `number` and the real `total`, their room taken from the page.
- Native tables with named columns: rows as hashes or objects, per-column `title`, `width`, `align` and font, a header repeated on every page, `stripes`, and cells measured in the font they draw in.
- `image`, `table`, `pdf_page`, `qr_code`, `barcode` and `data_matrix` are boxes of the layout, with `align`.
- `pdf_page` draws a page of an existing PDF like an image, and `background_pdf` puts a letterhead under every page (also `start_new_page(background_pdf:)`); each page is written once.
- Vector barcodes in pure Ruby: QR codes (versions 1 to 40, all levels), Code 128, EAN-13, EAN-8, Code 39, ITF-14 with check digits, and DataMatrix ECC 200.
- Tagged PDF: `pdf: :ua` writes PDF/UA-1 and `pdf_a: :a` PDF/A-3a from the boxes' `role:` (headings, paragraphs, lists, figures with `alt:`, tables) and `lang:`, headers, footers and decoration as artifacts; what breaks the standard raises `PdfUaViolation` or `PdfAViolation`. Headings also make the PDF's bookmarks, tagged or not.
- Rails: `render pdf:` in controllers, `.pdf.rb` templates drawing on `document` with the view's helpers, `Gamba.eager_load!` before Rails eager loads, and Active Storage attachments read by `image` and `pdf_page` without a temporary file. No Rails dependency.
- Test helpers: `require "gamba/minitest"` (`assert_pdf_text`, `assert_same_pages`, `assert_valid_pdf`, `assert_pdf_a`) and `require "gamba/rspec"` (`have_pdf_text`, `have_same_pages_as`, `be_a_valid_pdf`, `be_pdf_a`), with failures that say what the page reads instead.
- Unknown faces in Gamba's own API raise an `ArgumentError` saying what to name instead, such as the family `Courier` with `weight: :bold` rather than `Courier-Bold`.

**Faster**
- Text in a font loaded with `features: %i[liga kern]` is no longer about three times slower to render than without them: shaping builds nothing per glyph and reads each kerned pair once per document, for the same bytes.

**Fixed**
- `Gamba.combine` gives a copied page without resources an empty dictionary, as ISO 32000-1 requires; qpdf 12.4 warned about such pages.

## [2.0.2] — 2026-11-07

SVGs that users send can no longer crash or stall a server through `<use>`, `<image>` or `<tref>`.

**Fixed**
- An SVG loaded through `<use>` or `<image>` is checked like the document, attributes included: a `data:` URL nested
  thousands of levels deep overflowed the stack, and entities in an attribute raised `RuntimeError`.
- `<tref>` draws through the `<use>` path: a tref inside its own text no longer overflows the stack, one to a missing
  id no longer raises `NoMethodError`, and trefs doubling at each level stop at the 20,000-element budget.
- Embedded SVG images share the budget of the SVG that embeds them and stop at 16 levels, and `data:` URLs are
  decoded once per document.
- An `@font-face` that is not a font becomes a warning, and a table with no cells draws nothing instead of raising
  `NoMethodError`.
- addressable 2.9.1 or later is required: before it, an `@import` path took quadratic time to resolve
  (GHSA-qq38-m9mg-xjj5).

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

[Unreleased]: https://github.com/levups/gamba/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/levups/gamba/compare/v2.0.2...v2.1.0
[2.0.2]: https://github.com/levups/gamba/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/levups/gamba/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/levups/gamba/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/levups/gamba/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/levups/gamba/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/levups/gamba/releases/tag/v1.0.0
