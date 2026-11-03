# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "tempfile"

# Ligatures and GPOS kerning, applied only to fonts loaded with features: they move pixels away from Prawn's.
class OpenTypeFeaturesTest < Minitest::Test
  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")

  def setup
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)
  end

  def test_a_ligature_stands_for_all_its_characters
    layout = PrawnX::TrueType::OpenTypeLayout.new(PrawnX::TrueType::File.open(FONT), %i[liga])

    assert_equal [["f".ord, "i".ord]], layout.shape("fi".codepoints).map(&:last)
  end

  def test_text_with_ligatures_extracts_as_typed
    pdf = Prawn::Document.new {
      font FONT, features: %i[liga kern]
      text "office AVATAR"
    }.render

    assert_equal "office AVATAR", extracted_text(pdf)
  end

  def test_gpos_kerning_draws_kerned_pairs_closer
    plain = Prawn::Document.new {
      font FONT
      @width = width_of("AVATAR", kerning: false)
    }
    kerned = Prawn::Document.new {
      font FONT, features: %i[kern]
      @width = width_of("AVATAR", kerning: true)
    }

    assert_operator kerned.instance_variable_get(:@width), :<, plain.instance_variable_get(:@width)
  end

  def test_without_features_a_font_measures_like_prawn
    with_features = Prawn::Document.new {
      font FONT, features: %i[liga]
      @width = width_of("office", kerning: false)
    }
    without = Prawn::Document.new {
      font FONT
      @width = width_of("office", kerning: false)
    }

    refute_equal without.instance_variable_get(:@width), with_features.instance_variable_get(:@width)
  end

  private

  def extracted_text(pdf)
    Tempfile.create(["features", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Oracle.mutool("draw", "-F", "txt", "-o", "-", file.path).force_encoding(Encoding::UTF_8).strip
    end
  end
end
