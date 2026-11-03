# frozen_string_literal: true

require_relative "test_helper"
require "prawnx"

# Fonts may come from users: a malformed one must fail with an error, not exhaust memory or read past its data.
class TrueTypeTest < Minitest::Test
  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")

  def setup
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)
  end

  def test_a_format_12_cmap_cannot_map_past_unicode
    cmap = [0, 1, 3, 10, 12].pack("n3 n N") + [12, 0, 28, 0, 1].pack("n2 N3") + [0x10FFF0, 0xFFFFFFFF, 1].pack("N3")
    font = PrawnX::TrueType::File.new(font_with_table("cmap", cmap))

    assert_equal 16, font.glyph_by_code.size
  end

  def test_a_format_12_cmap_cannot_declare_more_groups_than_it_holds
    cmap = [0, 1, 3, 10, 12].pack("n3 n N") + [12, 0, 28, 0, 0x7FFFFFFF].pack("n2 N3") + [65, 66, 1].pack("N3")
    font = PrawnX::TrueType::File.new(font_with_table("cmap", cmap))

    assert_equal({65 => 1, 66 => 2}, font.glyph_by_code)
  end

  def test_a_truncated_composite_glyph_raises
    font = PrawnX::TrueType::File.new(File.binread(FONT))
    subset = PrawnX::TrueType::Subset.new(font)
    truncated_composite = [-1, 0, 0, 0, 0].pack("s>5") + [0x0020].pack("n")

    assert_raises(PrawnX::TrueType::Error) { subset.send(:remap_components, truncated_composite) }
  end

  def test_a_kern_subtable_cannot_declare_more_pairs_than_it_holds
    records = [36, 57, -40, 36, 58, 25].pack("n2 s> n2 s>") + [57, 36].pack("n2")
    font = PrawnX::TrueType::File.new(font_with_table("kern", kern_table([3, 12, 1, 6].pack("n4") + records)))

    assert_equal [-40, 25, nil], [font.kerning_offset(36, 57), font.kerning_offset(36, 58), font.kerning_offset(57, 36)]
  end

  def test_a_kern_subtable_shorter_than_its_header_raises
    assert_raises(PrawnX::TrueType::Error) { PrawnX::TrueType::File.new(font_with_table("kern", kern_table([3].pack("n")))) }
  end

  private

  def kern_table(format0)
    [0, 1, 0, 6 + format0.bytesize, 0x0001].pack("n5") + format0
  end

  # DejaVu Sans with one table replaced: the directory is rewritten to point at the new bytes, appended last.
  def font_with_table(tag, bytes)
    font = File.binread(FONT)
    table_count = font.unpack1("@4 n")
    record = (0...table_count).map { 12 + (it * 16) }.find { font.byteslice(it, 4) == tag }
    font[record + 8, 8] = [font.bytesize, bytes.bytesize].pack("N2")
    font + bytes
  end
end
