# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "prawn"

class WatermarkTest < Minitest::Test
  def test_every_page_carries_the_watermark
    document = Prawn::Document.new(watermark: {text: "Draft", angle: 0}) do
      text "alice"
      start_new_page
      start_new_page(size: "A3")
    end

    assert_equal [%w[Draft alice], %w[Draft], %w[Draft]], Gamba::PdfCheck.text_lines(document.render).map(&:sort)
  end

  def test_it_is_written_once_per_page_size
    document = Prawn::Document.new(watermark: "Draft") do
      49.times { start_new_page }
      start_new_page(size: "A3")
      start_new_page(size: "A3")
    end

    assert_equal 2, uncompressed(document.render).scan("/Subtype /Form").size
  end

  def test_it_lies_beneath_what_the_page_draws
    whited_out = lambda do |options|
      Prawn::Document.new(**options, margin: 0) do
        fill_color "ffffff"
        fill_rectangle [0, bounds.top], bounds.width, bounds.height
      end.render
    end

    Dir.mktmpdir do |directory|
      plain, watermarked = [{}, {watermark: {text: "Draft", opacity: 1}}].each_with_index.map do |options, index|
        File.join(directory, "#{index}.pdf").tap { File.binwrite(_1, whited_out.call(options)) }
      end

      assert_empty Oracle.rendered_pixel_differences(plain, watermarked)
    end
  end

  def test_without_a_size_it_spans_most_of_the_line_through_the_centre
    glyphs = Oracle.text_layout(Prawn::Document.new(watermark: {text: "Draft for alice", angle: 0}).render).first.glyphs
    left, right = glyphs.map { _1[3] }.minmax

    assert_operator left, :>, 0
    assert_operator right, :<, 612
    assert_in_delta 306, (left + right) / 2, 30
  end

  def test_its_text_is_an_artifact_outside_the_structure_tree
    document = Gamba.document(pdf: :ua, lang: "en", info: {Title: "Report"}, watermark: "Draft") do |document|
      document.register_font "Sans", normal: font_file("DejaVuSans.ttf"), bold: font_file("DejaVuSans-Bold.ttf")
      document.style :default, font: "Sans"
      document.text "Report", role: :h1
    end

    assert_includes uncompressed(document.to_s), "/Artifact <</Type /Pagination /Subtype /Watermark>> BDC"
  end

  def test_an_unknown_option_or_an_empty_text_raises
    assert_raises(ArgumentError) { Prawn::Document.new(watermark: {text: "Draft", colour: "ff0000"}) }
    assert_raises(ArgumentError) { Prawn::Document.new(watermark: {color: "ff0000"}) }
    assert_raises(ArgumentError) { Prawn::Document.new(watermark: "") }
  end

  private

  def font_file(name)
    File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts", name)
  end

  def uncompressed(pdf)
    Gamba::PdfCheck.with_path(pdf) { |path| Open3.capture2("qpdf", "--qdf", "--object-streams=disable", path, "-").first.b }
  end
end
