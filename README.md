# PrawnX

Prawn's API, rewritten for speed: the same pages, pixel for pixel, in lighter files, faster and with less memory.

https://next-gen-gems.github.io/prawnx/

## Installation

```ruby
# Gemfile
gem "prawnx" # instead of prawn, prawn-table and prawn-svg
```

`pdf.table` and `pdf.svg` work without any other gem; `require "prawn/table"` and `require "prawn-svg"` keep
working.

PrawnX needs Ruby 3.3 or later, and refuses to load when the prawn gem is in the bundle too.

The gem has its own version, `PrawnX::VERSION`. `Prawn::VERSION` is the version of the Prawn API it reproduces,
2.5.0, so code that checks Prawn's version keeps working.

## Usage

Code written for Prawn runs unchanged:

```ruby
Prawn::Document.generate("hello.pdf") do
  text "Hello, World!"
  table [%w[SKU Qty], %w[A-1 2]]
end
```

## Beyond Prawn

What would move pixels away from Prawn's stays off unless asked for.

```ruby
# OpenType ligatures and GPOS pair kerning, per font
font "Inter.ttf", features: %i[liga kern]

# PDF/A-3b: XMP metadata, sRGB output intent, file identifier; standard fonts and encryption raise
Prawn::Document.new(pdf_a: true, info: {Title: "Invoice INV-2026-0001"}) do
  font "Inter.ttf"
  # …
  factur_x File.read("factur-x.xml"), profile: :en16931 # Factur-X: minimum, basic_wl, basic, en16931, extended
end

# Before a server forks: load TrueType and SVG support once, shared by every worker
PrawnX.eager_load!

# Pages of PDFs written elsewhere, one after the other: carrier labels, supplier invoices (instead of combine_pdf)
PrawnX.combine([label, other_label], page_size: [288, 432], orientation: :portrait)
```

OpenType fonts with CFF outlines (`.otf`) embed like TrueType ones, and render like the font itself. PrawnX does
not build the Factur-X XML: it embeds the one the invoicing system produced.

SVG images do not fetch anything from the web unless asked to (`svg data, enable_web_requests: true`): prawn-svg
0.40 fetches by default, which lets a submitted SVG make the server request any URL. prawn-svg 1.0 plans the same
default.

`PrawnX.combine` reads xref tables, cross-reference and object streams, incremental updates, and files encrypted
with an owner password only (RC4, AES-128, AES-256); a file that needs a user password raises
`Prawn::Errors::EncryptedPDF`, a damaged one it cannot repair `Prawn::Errors::MalformedPDF`. Content streams are
copied as they were encoded, and what several sources share (a carrier's fonts and logo) is written once. With
`page_size`, each page is scaled from its lower left corner to fit, keeping its proportions; with `orientation`, a
page the other way round turns a quarter counterclockwise, as combine_pdf does. A `/Rotate` is applied to the
content first, where combine_pdf left it to the viewer. Outlines, forms and tagged structure are not carried over.

## Comparing an app's PDFs

`script/capture_pdfs.rb` writes every PDF an app's test suite renders, named after its test. Run the suite under
Prawn, then under PrawnX, and compare both directories with `Oracle.pdf_differences`:

```sh
PRAWNX_CAPTURE_DIRECTORY=tmp/prawn RUBYOPT=-r/path/to/prawnx/script/capture_pdfs.rb bin/rails test
```

## Performance

`bundle exec rake bench` renders each document of `bench/documents` with Prawn 2.5 and with PrawnX, each in its own
YJIT process, and writes `docs/benchmarks.json`. Median of 20 renders, on Ruby 4.0.9:

| Document | Prawn | PrawnX | Allocations, Prawn → PrawnX | Weight, Prawn → PrawnX |
|---|---:|---:|---:|---:|
| Invoice, one page | 22.9 ms | 5.2 ms | 167,104 → 32,601 | 45,076 → 30,741 bytes |
| Report, 50 pages | 499.8 ms | 201.5 ms | 3,064,282 → 1,932,990 | 209,010 → 166,070 bytes |
| Catalog, 1,000 table rows | 570.5 ms | 266.9 ms | 3,999,685 → 2,085,019 | 155,369 → 137,109 bytes |

Charts and peak memory: https://next-gen-gems.github.io/prawnx/benchmarks.html

## Development

- An oracle renders every example of Prawn's and prawn-table's manuals and every sample SVG of prawn-svg, with
  Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 and with PrawnX, each in its own process, and
  compares their pages, their text and its positions to 0.01 pt, their pixels at 150 dpi in two renderers that
  share no code (MuPDF and Poppler), their validity
  (`qpdf --check`) and their weight. Examples listed in `test/oracle_passing.txt` must stay identical; one that
  becomes identical must join the list.
- A seeded fuzzer writes random documents (text in all its options, boxes, columns, tables, shapes, pages) and
  compares them the same way: `FUZZ_SEED=42 FUZZ_CASES=500 bundle exec ruby -Itest test/fuzz_test.rb`, and
  `ruby -Itest script/fuzz_minimize.rb tmp/fuzz/documents/fuzz_0042.rb` shrinks a failing one. CI adds 300 from a
  fresh seed on every run.
- An input fuzzer corrupts sample PNGs, JPEGs and fonts (flipped bytes, truncations, forged lengths): each must
  render or raise an error PrawnX names, never crash inside a parser, hang or exhaust memory. PNG data inflates
  no further than its header announces.
- `test/divergences.yml` lists Prawn's bugs PrawnX fixes, each with the specification that proves it and the exact
  differences the oracle must report. `test/oracle_examples` holds documents of our own for what the manual
  does not show.
- PDF/A documents are checked by veraPDF when it is installed (`brew install verapdf`).
- `test/contract/prawn-2.5.0.yml`, generated by `script/contract_extract.rb`, lists Prawn's public methods; PrawnX
  must accept every call Prawn accepts on those of its contract, settled in `test/contract/decisions.yml`.

Prawn runs from its own bundle, `oracle/Gemfile`. The oracle needs `mutool`, `pdftoppm` and `qpdf` (`brew install
mupdf-tools poppler qpdf`), and Prawn's manual and data, which `rake corpus:fetch` downloads into the ignored `corpus/cache`.

```sh
bundle install && BUNDLE_GEMFILE=oracle/Gemfile bundle install
bundle exec rake corpus:fetch
bundle exec rake test
ORACLE_CANDIDATE=prawn bundle exec rake test # Prawn against itself: proves the oracle
bundle exec rake bench
bundle exec rubocop
```

### Releasing

Changes go under `## [Unreleased]` in `CHANGELOG.md` as they land. To release them, from an up-to-date `main`
whose CI is green:

```sh
bin/release minor --dry-run   # the notes and the changes, nothing written
bin/release minor             # or patch, major, or an exact version such as 1.2.0
```

`bin/release` dates the Unreleased section, bumps the version, commits, and pushes the commit with a signed tag
`vX.Y.Z`. The tag starts the Release workflow, which publishes the gem to RubyGems through trusted publishing and
creates the GitHub release with the version's notes and the `.gem`.

## License

By Level UP Solutions. PrawnX is derived from Prawn, PDF::Core, TTFunk and prawn-table, by Gregory Brown and their
contributors, and is licensed like them: under Matz's original terms for Ruby, or the GPLv2, or the GPLv3. Its SVG
support comes from prawn-svg, by Roger Nesbitt, under the MIT license. See `LICENSE`.
