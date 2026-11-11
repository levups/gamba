# Gamba

Gamba is a Ruby library that writes PDF files: invoices, reports, labels, anything you can lay out as text, tables,
images and shapes. It is a faster rewrite of [Prawn](https://github.com/prawnpdf/prawn), the most widely used PDF
library for Ruby, together with its two companion gems, prawn-table and prawn-svg.

Code written for Prawn 2.5 runs on Gamba unchanged and draws the same pages, down to the pixel. The difference is
speed and size: a one-page invoice renders about five times faster and the file is a quarter lighter (see
[Performance](#performance)).

Website and guide: https://levups.github.io/gamba/

## Installation

Gamba needs Ruby 3.3 or later. In your Gemfile, replace `prawn`, `prawn-table` and `prawn-svg` with one line:

```ruby
gem "gamba"
```

Gamba refuses to load if the prawn gem is in the same bundle, so remove it. Your existing `require "prawn"`,
`require "prawn/table"` and `require "prawn-svg"` lines keep working, and `pdf.table` and `pdf.svg` are available
without them.

## A first document

```ruby
require "prawn"

Prawn::Document.generate("hello.pdf") do
  text "Hello, World!"
  table [%w[SKU Qty], %w[A-1 2]]
end
```

This writes `hello.pdf` with a line of text and a two-row table. Everything else Prawn documents works the same
way: fonts, colors, images, columns, page numbers, links, encryption. Prawn's manual applies as it is, and
[the guide](https://levups.github.io/gamba/guide.html) covers what Gamba adds.

The constant is still `Prawn`, so you don't have to rename anything. `Prawn::VERSION` reports `2.5.0`, the
version of the API Gamba reproduces, for code that checks it. Gamba's own version is `Gamba::VERSION`.

## What Gamba adds

Anything that would change how a page looks compared with Prawn is off until you ask for it.

An API of its own, next to Prawn's. The block receives the document instead of running inside it, options are
keywords, and a mistyped one raises instead of being ignored:

```ruby
document = Gamba.document(page_size: "A4", lang: "en") do |document|
  document.style :title, size: 18, weight: :bold
  document.text "Invoice INV-2026-0001", style: :title
  document.draw InvoiceLines.new(invoice) # any object with call(document)
end
document.write("invoice.pdf")
```

Layout is described instead of computed: a `stack` puts boxes one under the other and breaks pages between them, a
`row` puts them side by side, and each is measured before anything is drawn.

```ruby
document.row(gap: 24, padding: 12, background: "f5f5f5") do |row|
  row.stack(gap: 4) { |stack| stack.text "Alice Martin", style: :title; stack.text "1 Example Street" }
  row.text "Due on 1 December 2026", width: 150, align: :right
end
```

Code written for Prawn adopts it one block at a time, `gamba { |document| document.text "Total", style: :title }`,
and `document.prawn` gives a native document all of Prawn's API. A header and a footer are declared once, and know
their page:

```ruby
document.footer(gap: 12) { |footer, page| footer.text "Page #{page.number} of #{page.total}", align: :center }
```

Text, styles, components, stacks, rows, tables, images, headers and footers are there today; tables with named
columns and grids come next ([the plan](https://github.com/levups/gamba/issues/69)).

Ligatures and kerning from OpenType fonts, per font:

```ruby
font "Inter.ttf", features: %i[liga kern]
```

PDF/A-3b archival files, and Factur-X electronic invoices (the French and German standard that embeds the invoice
data as XML inside the PDF). Gamba embeds the XML your invoicing system produced; it does not build it.

```ruby
Prawn::Document.new(pdf_a: true, info: {Title: "Invoice INV-2026-0001"}) do
  font "Inter.ttf" # PDF/A needs embedded fonts: the 14 standard ones raise, and so does encryption
  # ...
  factur_x File.read("factur-x.xml"), profile: :en16931 # or minimum, basic_wl, basic, extended
end
```

Merging existing PDFs, such as carrier labels or supplier invoices, one page after another. This replaces the
combine_pdf gem for that use:

```ruby
Gamba.combine([label, other_label], page_size: [288, 432], orientation: :portrait)
```

Loading font and SVG support once, before a server such as Puma or Unicorn forks its workers, so they share it in
memory:

```ruby
Gamba.eager_load!
```

### More on combining PDFs

`Gamba.combine` takes the bytes of each PDF and returns the bytes of the merged one. It reads the cross-reference
formats PDF writers use, including incremental updates, and files encrypted with an owner password only (RC4,
AES-128 and AES-256). A file that needs a password to open raises `Prawn::Errors::EncryptedPDF`, and a damaged one
it cannot repair raises `Prawn::Errors::MalformedPDF`.

Pages are copied as they were encoded, and resources several files share, like a carrier's fonts and logo, are
written once. With `page_size`, each page is scaled from its lower left corner to fit, keeping its proportions.
With `orientation`, a page the other way round turns a quarter counterclockwise, as combine_pdf does. A page's
`/Rotate` is applied to its content, where combine_pdf left it to the viewer. Outlines, forms and tagged structure
are not carried over.

## Files your users send

Applications often put user content into PDFs: an uploaded logo, a font, a name typed in a form, a PDF to attach.
Any of it can be built to attack the server that renders it.

- SVG images fetch nothing from the web unless you pass `enable_web_requests: true`. prawn-svg 0.40 fetched by
  default, so a submitted SVG could make your server request any URL. prawn-svg 1.0 plans the same default as
  Gamba.
- An SVG reads only what you allow. Base64 `data:` URLs of PNG, JPEG and SVG images always load; `http` and
  `https` URLs need `enable_web_requests: true`; files need `enable_file_requests_with_root`, and only regular
  files inside that directory load, symbolic links in it followed. Any other URL, path or scheme is skipped with a
  warning, and an entity the SVG declares from a file or URL is never read.
- An SVG can't make Gamba loop or run out of stack through references (`<use>`, `<tref>`, gradients) or deep
  nesting. An SVG it loads with `<use>` or `<image>` is checked the same way, SVG images stop 16 levels inside
  one another, and they draw within the budget of the SVG that embeds them.
- Fonts an SVG declares with `@font-face` disappear once it is drawn, and one that is not a font is left out. In
  prawn-svg, an uploaded SVG declaring a "Helvetica" font changed the font of the application's own text.
- A damaged or malicious PNG, JPEG, TrueType or OpenType file either renders or raises an error Gamba names
  (`Prawn::Errors::UnsupportedImageType`, `Prawn::Images::JPG::FormatError`, `Gamba::TrueType::Error`, or
  `Prawn::Errors::CannotFit` when a damaged font makes a glyph wider than the page). A PNG
  inflates no further than the size its header gives. CI corrupts sample files on every run to check this.
- `Gamba.combine` stops at 64 levels of nested arrays and dictionaries and at 256 MB of decompressed data, and
  ignores references that lead back to themselves, so a crafted PDF can't send it into a loop or fill
  memory.
- Text with inline formatting (`inline_format: true`) is parsed in linear time, whatever the markup.
- The `/ID` of an encrypted PDF depends on its passwords, so it reveals nothing about the content to someone
  without them.

Inline formatting still turns `<link href="...">` into a clickable link. Escape user text before you put it inside
markup. A word with no space to break at, thousands of characters long, takes time that grows with the square of its
length, as in Prawn: limit the length of what users type.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Checking your app's PDFs

Before switching, you can compare what your app produces under both libraries. `script/capture_pdfs.rb` saves
every PDF your test suite renders, named after the test. Run the suite once with Prawn and once with Gamba:

```sh
GAMBA_CAPTURE_DIRECTORY=tmp/prawn RUBYOPT=-r/path/to/gamba/script/capture_pdfs.rb bin/rails test
```

Then compare the two directories with `Oracle.pdf_differences`, from Gamba's test support.

## Performance

`bundle exec rake bench` renders each document in `bench/documents` with Prawn 2.5 and with Gamba, in 7 fresh
YJIT processes each, taking turns. Each process times 20 renders, and the table shows the median of the 7, on
Ruby 4.0.9:

| Document | Prawn | Gamba | Allocations, Prawn → Gamba | Weight, Prawn → Gamba |
|---|---:|---:|---:|---:|
| Invoice, one page | 22.1 ms | 4.5 ms | 163,881 → 31,366 | 38,766 → 28,992 bytes |
| Report, 101 pages | 559.4 ms | 216.0 ms | 3,350,853 → 2,089,008 | 207,815 → 164,924 bytes |
| Catalog, 1,000 table rows | 544.9 ms | 265.6 ms | 3,979,977 → 2,078,343 | 147,731 → 134,082 bytes |

Files are lighter because Gamba compresses streams and packs objects together, which PDF 1.5 allows and Prawn
doesn't do. Charts and peak memory are on the [benchmarks page](https://levups.github.io/gamba/benchmarks.html).

## How we know the pages are the same

The test suite renders every example of Prawn's and prawn-table's manuals, and every sample SVG of prawn-svg, once
with the original gems and once with Gamba. For each pair it compares the text and its position to 0.01 pt, the
pixels at 150 dpi in two unrelated renderers (MuPDF and Poppler), whether `qpdf --check` accepts the file, and its
size. We call this the oracle.

Gamba does not copy Prawn's bugs. When Prawn crashes, writes an invalid PDF or contradicts its own documentation,
Gamba fixes it, and the [compatibility page](https://levups.github.io/gamba/compatibility.html) lists each fix with
its proof.

## Development

Prawn runs from its own bundle, `oracle/Gemfile`, so the oracle can compare the two. The tests need `mutool`,
`pdftoppm` and `qpdf` (`brew install mupdf-tools poppler qpdf`), and Prawn's manual and sample data, which
`rake corpus:fetch` downloads into `corpus/cache`. Without that cache, the comparison tests are skipped.

```sh
bundle install && BUNDLE_GEMFILE=oracle/Gemfile bundle install
bundle exec rake corpus:fetch
bundle exec rake test
bundle exec rubocop
```

Other commands:

```sh
ORACLE_CANDIDATE=prawn bundle exec rake test                     # Prawn against itself, to check the oracle
FUZZ_SEED=42 FUZZ_CASES=500 bundle exec ruby -Itest test/fuzz_test.rb  # random documents, compared with Prawn
INPUT_FUZZ_SEED=42 INPUT_FUZZ_CASES=400 bundle exec ruby -Itest test/input_fuzz_test.rb  # corrupted images and fonts
bundle exec rake bench                                           # writes docs/benchmarks.json
```

`ruby -Itest script/fuzz_minimize.rb tmp/fuzz/documents/fuzz_0042.rb` shrinks a failing fuzz document. PDF/A
files are also checked by veraPDF when it is installed (`brew install verapdf`).

The files that define what "compatible" means:

- `test/oracle_passing.txt`: examples that must stay identical to Prawn's. One that becomes identical joins it.
- `test/divergences.yml`: Prawn bugs Gamba fixes, with the specification that proves each one and the exact
  differences the oracle must find.
- `test/oracle_examples`: documents of our own, for cases the manuals don't show.
- `test/contract/prawn-2.5.0.yml`: Prawn's public methods, generated by `script/contract_extract.rb`. Every call
  Prawn accepts must keep working; exceptions are settled in `test/contract/decisions.yml`.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

### Releasing

Pull requests leave `CHANGELOG.md` alone. A release starts by writing its notes under `## [Unreleased]`, from the
pull requests merged since the last tag, without committing them. Then, from an up-to-date `main` with green CI:

```sh
bin/release minor --dry-run   # shows the notes and the changes, writes nothing
bin/release minor             # or patch, major, or an exact version such as 1.2.0
```

`main` takes no direct push, so `bin/release` dates the notes and bumps the version on a `release/vX.Y.Z` branch,
opens a pull request that merges itself once CI is green, and waits for it. It then pushes a signed `vX.Y.Z` tag on
the merge commit (`bin/release --tag X.Y.Z` does it if you stopped waiting). The tag starts the Release workflow,
which publishes the gem to RubyGems through trusted publishing and creates the GitHub release with the notes and
the `.gem`.

## License

By Level UP Solutions. Gamba is derived from Prawn, PDF::Core, TTFunk and prawn-table, by Gregory Brown and their
contributors, and is licensed like them: under Matz's original terms for Ruby, or the GPLv2, or the GPLv3. Its SVG
support comes from prawn-svg, by Roger Nesbitt, under the MIT license. See `LICENSE`.
