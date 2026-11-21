# frozen_string_literal: true

require_relative "lib/gamba/version"

Gem::Specification.new do |spec|
  spec.name = "gamba"
  spec.version = Gamba::VERSION
  spec.authors = ["Level UP Solutions"]
  spec.summary = "PDFs from layout you describe, tagged for screen readers; runs Prawn code unchanged, faster"
  spec.description = "Gamba is a Ruby library that writes PDF files from stacks, rows, tables, headers and footers it " \
                     "measures and places, tagged for PDF/UA. It also runs code written for Prawn 2.5, prawn-table " \
                     "and prawn-svg unchanged, drawing the same pages faster and in lighter files."
  spec.homepage = "https://github.com/levups/gamba"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://levups.github.io/gamba/",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.licenses = %w[Nonstandard GPL-2.0-only GPL-3.0-only MIT]
  spec.required_ruby_version = ">= 3.3"
  # css_parser joins @import paths with addressable, which before 2.9.1 took quadratic time on dot segments.
  spec.add_dependency "addressable", ">= 2.9.1", "< 3"
  spec.add_dependency "css_parser", ">= 1.17.1", "< 4"
  spec.add_dependency "matrix", "~> 0.4"
  spec.add_dependency "rexml", ">= 3.4.2", "< 4"
  spec.files = Dir["lib/**/*.rb", "data/**/*", "LICENSE", "LICENSE-prawn-svg", "COPYING", "GPLv2", "GPLv3", "README.md", "CHANGELOG.md"]
end
