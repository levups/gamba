# frozen_string_literal: true

require_relative "test_helper"
require "prawnx"

# Fonts may come from users: each table format maps as the OpenType specification says, and a malformed font
# fails with an error, not exhausting memory or reading past its data.
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

  def test_a_format_6_cmap_maps_each_code_to_its_glyph
    cmap = [0, 1, 3, 1, 12].pack("n3 n N") + [6, 18, 0, 65, 4, 36, 37, 38, 39].pack("n9")
    font = PrawnX::TrueType::File.new(font_with_table("cmap", cmap))

    assert_equal({65 => 36, 66 => 37, 67 => 38, 68 => 39}, font.glyph_by_code)
  end

  def test_a_format_10_cmap_maps_each_code_to_its_glyph
    cmap = [0, 1, 3, 10, 12].pack("n3 n N") + [10, 0, 28, 0, 0x10400, 4].pack("n2 N4") + [36, 37, 38, 39].pack("n4")
    font = PrawnX::TrueType::File.new(font_with_table("cmap", cmap))

    assert_equal({0x10400 => 36, 0x10401 => 37, 0x10402 => 38, 0x10403 => 39}, font.glyph_by_code)
  end

  def test_gpos_class_kerning_reads_each_glyph_class_of_a_format_1_class_definition
    layout = PrawnX::TrueType::OpenTypeLayout.new(PrawnX::TrueType::File.new(font_with_table("GPOS", class_kerning_gpos)), %i[kern])

    assert_equal [-50, -80, -30], [layout.kerning(36, 57), layout.kerning(37, 57), layout.kerning(38, 57)]
  end

  def test_a_truncated_composite_glyph_raises
    font = PrawnX::TrueType::File.new(File.binread(FONT))
    subset = PrawnX::TrueType::Subset.new(font)
    truncated_composite = [-1, 0, 0, 0, 0].pack("s>5") + [0x0020].pack("n")

    assert_raises(PrawnX::TrueType::Error) { subset.send(:remap_components, truncated_composite) }
  end

  def test_a_simple_glyph_shorter_than_its_contours_raises
    font = PrawnX::TrueType::File.new(File.binread(FONT))
    subset = PrawnX::TrueType::Subset.new(font)
    two_contours_one_end_point = [2, 0, 0, 0, 0].pack("s>5") + [5].pack("n")

    assert_raises(PrawnX::TrueType::Error) { subset.send(:maximum_profile, [], [two_contours_one_end_point], 1) }
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

  # A "kern" feature for "latn" with one class pair adjustment: glyphs 36, 37 and 38 are classes 1, 2 and 3
  # before glyph 57, class 1, both in format 1 class definitions.
  def class_kerning_gpos
    pair_adjustment = [2, 32, 0x0004, 0, 42, 54, 4, 2].pack("n8") +
      [0, 0, 0, -50, 0, -80, 0, -30].pack("s>8") +
      [1, 3, 36, 37, 38].pack("n5") +
      [1, 36, 3, 1, 2, 3].pack("n6") +
      [1, 57, 1, 1].pack("n4")
    script_list = [1].pack("n") + "latn" + [8, 4, 0, 0, 0xFFFF, 1, 0].pack("n7")
    feature_list = [1].pack("n") + "kern" + [8, 0, 1, 0].pack("n4")
    lookup_list = [1, 4, 2, 0, 1, 8].pack("n6")
    [1, 0, 10, 10 + script_list.bytesize, 10 + script_list.bytesize + feature_list.bytesize].pack("n5") +
      script_list + feature_list + lookup_list + pair_adjustment
  end

  def kern_table(format0)
    [0, 1, 0, 6 + format0.bytesize, 0x0001].pack("n5") + format0
  end

  # DejaVu Sans with one table replaced: the directory is rewritten to point at the new bytes, appended last.
  def font_with_table(tag, bytes)
    font = File.binread(FONT)
    table_count = font.unpack1("@4 n")
    record = (0...table_count).map { |index| 12 + (index * 16) }.find { |offset| font.byteslice(offset, 4) == tag }
    font[record + 8, 8] = [font.bytesize, bytes.bytesize].pack("N2")
    font + bytes
  end
end
