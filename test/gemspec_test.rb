# frozen_string_literal: true

require_relative "test_helper"

class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_every_license_file_ships_with_the_gem
    shipped = Dir.chdir(ROOT) { Gem::Specification.load("gamba.gemspec").files }
    license_files = Dir.children(ROOT).grep(/\A(LICENSE|COPYING|GPL)/)

    assert_empty license_files - shipped
  end
end
