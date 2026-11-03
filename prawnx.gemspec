# frozen_string_literal: true

require_relative "lib/prawnx/version"

Gem::Specification.new do |spec|
  spec.name = "prawnx"
  spec.version = PrawnX::VERSION
  spec.authors = ["Level UP Solutions", "Clément Joubert"]
  spec.summary = "Prawn's API, rewritten for speed: same pages, lighter files"
  spec.homepage = "https://github.com/next-gen-gems/prawnx"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://next-gen-gems.github.io/prawnx/",
    "rubygems_mfa_required" => "true"
  }
  spec.licenses = %w[Nonstandard GPL-2.0-only GPL-3.0-only]
  spec.required_ruby_version = ">= 3.4"
  spec.add_dependency "css_parser", ">= 1.17.1", "< 4"
  spec.add_dependency "matrix", "~> 0.4"
  spec.add_dependency "rexml", ">= 3.4.2", "< 4"
  spec.files = Dir["lib/**/*.rb", "data/**/*", "LICENSE", "LICENSE-prawn-svg", "COPYING", "GPLv2", "GPLv3", "README.md", "CHANGELOG.md"]
end
