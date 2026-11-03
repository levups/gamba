# frozen_string_literal: true

require_relative "test_helper"
require "prawn"

class VersionTest < Minitest::Test
  def test_prawn_version_answers_the_reproduced_api
    assert_equal "2.5.0", Prawn::VERSION
  end

  def test_gem_version_counts_prawnx_releases_apart
    refute_equal Prawn::VERSION, PrawnX::VERSION
    assert_equal PrawnX::VERSION, Gem::Specification.load(File.expand_path("../prawnx.gemspec", __dir__)).version.to_s
  end
end
