# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

class WatermarkTest < Minitest::Test
  LETTER = [612, 792].freeze
  ARTIFACT = "/Artifact <</Type /Pagination /Subtype /Watermark>> BDC"

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

  def test_each_page_size_is_drawn_to_its_own_geometry_whatever_became_of_the_page_that_opened_it
    document = Prawn::Document.new(watermark: {text: "Draft", angle: 0}) do
      start_new_page(size: "A3")
      go_to_page(1)
      start_new_page(size: "A5")
      start_new_page(size: "A4")
      delete_page(-1)
    end
    lefts = Oracle.text_layout(document.render).map { |page| page.glyphs.first[3] }

    # Without a size, a flat text spans four fifths of its page's width: it starts a tenth of the width in.
    # Pages open after the current one: letter, A5, A4, then A3, which delete_page removes.
    [612, 419.53, 595.28].zip(lefts).each { |width, left| assert_in_delta width / 10, left, 1 }
    deleted = Prawn::Document.new(watermark: "Draft") do
      start_new_page(size: "A3")
      delete_page(-1)
    end

    assert_equal 1, Oracle.text_layout(deleted.render).size
  end

  def test_it_lies_beneath_what_the_page_draws
    Dir.mktmpdir do |directory|
      plain = File.join(directory, "plain.pdf")
      watermarked = File.join(directory, "watermarked.pdf")
      File.binwrite(plain, whited_out)
      File.binwrite(watermarked, whited_out(watermark: {text: "Draft", opacity: 1}))

      assert_empty Oracle.rendered_pixel_differences(plain, watermarked)
    end
  end

  def test_without_a_size_the_whole_text_stays_inside_the_page
    ["Draft", "Courtesy translation for alice", "I"].each do |text|
      [nil, 0, 30, 90, -45, 135].each do |angle|
        border = page_border_grey_levels(Prawn::Document.new(watermark: {text:, angle:, color: "000000", opacity: 1}).render)

        assert_equal [255], border.uniq, "#{text.inspect} at #{angle.inspect}°"
      end
    end
  end

  def test_the_text_is_centred_on_the_page
    glyphs = Oracle.text_layout(Prawn::Document.new(watermark: {text: "Draft", angle: 0, size: 100}).render).first.glyphs
    left = glyphs.first[3]
    right = glyphs.last[3] + Prawn::Document.new.font("Helvetica", style: :bold).compute_width_of("t", size: 100)
    baseline_from_top = glyphs.first[4]

    assert_in_delta LETTER[0] / 2.0, (left + right) / 2, 1
    # Helvetica-Bold rises 71.8 and descends 20.7 at 100 points: the box between them centred on 396.
    assert_in_delta LETTER[1] - (396 - ((71.8 - 20.7) / 2)), baseline_from_top, 1
  end

  def test_a_page_opened_inside_a_text_state_block_draws_the_watermark_unchanged
    document = Prawn::Document.new(watermark: {text: "Draft", angle: 0}) do
      character_spacing(20) { text_rendering_mode(:stroke) { text "alice " * 2000 } }
    end
    first, second = Oracle.text_layout(document.render).first(2).map { |page| page.glyphs.select { _1[1] == "Helvetica-Bold" }.map { _1[3] } }

    assert_equal first, second
  end

  def test_its_font_defaults_to_the_default_font_family_and_its_bold_face_only_when_the_family_has_one
    skip CORPUS_MISSING_MESSAGE unless File.exist?(font_file("DejaVuSans.ttf"))

    regular = font_file("DejaVuSans.ttf")
    # The font the page uses is not the watermark's: without a default font family, it is Helvetica's bold face.
    by_path = Prawn::Document.new(watermark: {text: "Draft", angle: 0}) { font regular }
    assert_equal ["Helvetica-Bold"], Oracle.text_layout(by_path.render).first.glyphs.map { _1[1] }.uniq

    without_bold = Prawn::Document.new(watermark: {text: "Draft", angle: 0, font: "Sans"}) { font_families.update("Sans" => {normal: regular}) }
    assert_equal ["DejaVuSans"], Oracle.text_layout(without_bold.render).first.glyphs.map { _1[1] }.uniq
  end

  def test_under_pdf_a_without_a_font_it_says_it_needs_one
    raised = assert_raises(Prawn::Errors::PdfAViolation) { Prawn::Document.new(pdf_a: true, watermark: "Draft").render }

    assert_includes raised.message, "watermark needs font:"
  end

  def test_under_pdf_a_a_cmyk_color_is_refused_when_the_document_is_made
    raised = assert_raises(Prawn::Errors::PdfAViolation) do
      Prawn::Document.new(pdf_a: true, skip_page_creation: true, watermark: {text: "Draft", color: [0, 0, 0, 50]})
    end

    assert_includes raised.message, "watermark color"
  end

  def test_a_font_that_cannot_draw_it_names_the_watermark
    raised = assert_raises(Prawn::Errors::IncompatibleStringEncoding) { Prawn::Document.new(watermark: "Черновик").render }
    assert_includes raised.message, %(the watermark "Черновик")

    raised = assert_raises(Prawn::Errors::UnknownFont) { Prawn::Document.new(watermark: {text: "Draft", font: "Interr"}).render }
    assert_includes raised.message, %(the watermark "Draft")
  end

  def test_its_text_is_an_artifact_outside_the_structure_tree
    skip CORPUS_MISSING_MESSAGE unless File.exist?(font_file("DejaVuSans.ttf"))

    regular = font_file("DejaVuSans.ttf")
    bold = font_file("DejaVuSans-Bold.ttf")
    document = Gamba.document(pdf: :ua, lang: "en", info: {Title: "Report"}, watermark: {text: "Draft", angle: 0}) do |document|
      document.register_font "Sans", normal: regular, bold: bold
      document.style :default, font: "Sans"
      document.text "Report", role: :h1
    end
    pdf = document.to_s

    assert_equal 2, uncompressed(pdf).scan(ARTIFACT).size
    assert_includes Gamba::PdfCheck.text_lines(pdf).first, "Draft"
  end

  def test_its_options_are_checked_when_the_document_is_made
    ["", "​", "Draft\nCopy", "Draft Copy", true].each do |text|
      assert_raises(ArgumentError, text.inspect) { Prawn::Document.new(watermark: text) }
    end
    [
      {colour: "ff0000"}, {color: "red"}, {color: [0, 0, 0]}, {angle: "45"}, {angle: Float::NAN}, {size: -1}, {size: "40"},
      {size: Float::INFINITY}, {opacity: 2}, {style: :heavy}
    ].each do |option|
      assert_raises(ArgumentError, option.inspect) { Prawn::Document.new(watermark: {text: "Draft", **option}) }
    end
    assert_raises(ArgumentError) { Prawn::Document.new(watermark: {color: "ff0000"}) }
    Prawn::Document.new(watermark: {text: "Draft", opacity: nil, color: nil}).render
  end

  private

  def whited_out(**options)
    Prawn::Document.new(**options, margin: 0) do
      fill_color "ffffff"
      fill_rectangle [0, bounds.top], bounds.width, bounds.height
    end.render
  end

  # The grey level of every pixel on the edge of the first page, rendered at 36 dpi.
  def page_border_grey_levels(pdf)
    Gamba::PdfCheck.with_path(pdf) do |path|
      pgm = Open3.capture2("mutool", "draw", "-q", "-r", "36", "-c", "gray", "-F", "pgm", "-o", "-", path, "1").first.b
      width, height = pgm[/\AP5\s+(\d+)\s+(\d+)\s+255\s/, 0] && [$1.to_i, $2.to_i]
      pixels = pgm.byteslice(pgm.bytesize - (width * height), width * height).bytes.each_slice(width).to_a
      pixels.first + pixels.last + pixels.map(&:first) + pixels.map(&:last)
    end
  end

  def font_file(name)
    File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts", name)
  end

  def uncompressed(pdf)
    Gamba::PdfCheck.with_path(pdf) { |path| Open3.capture2("qpdf", "--qdf", "--object-streams=disable", path, "-").first.b }
  end
end
