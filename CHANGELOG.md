# Changelog

## 1.0.0 — unreleased

First release under next-gen-gems: Prawn 2.5, prawn-table 0.2.2 and prawn-svg 0.40.4 in one gem, rewritten for
speed.

- Same API and same pages as Prawn, pixel for pixel, in lighter files; `require "prawn/table"` and
  `require "prawn-svg"` keep working. PrawnX refuses to load next to the prawn gem.
- `PrawnX::VERSION` is the gem's; `Prawn::VERSION` stays 2.5.0, the API reproduced.
- Opt-in beyond Prawn: OpenType ligatures and GPOS kerning per font, CFF (`.otf`) fonts, PDF/A-3b and Factur-X,
  `PrawnX.eager_load!` before a server forks.
- SVG images fetch nothing from the web unless `enable_web_requests: true`.
- Runs on Ruby 3.3 and later, every Ruby still maintained.
