# frozen_string_literal: true

require_relative "test_helper"
require "prawn"

class PdfDateTest < Minitest::Test
  def test_a_date_keeps_the_minutes_of_its_offset
    assert_equal "(D:20261127120000+05'30')", PDF::Core.serialize(Time.new(2026, 11, 27, 12, 0, 0, "+05:30"))
    assert_equal "(D:20261127120000-03'30')", PDF::Core.serialize(Time.new(2026, 11, 27, 12, 0, 0, "-03:30"))
    assert_equal "(D:20261127120000+01'00')", PDF::Core.serialize(Time.new(2026, 11, 27, 12, 0, 0, "+01:00"))
  end
end
