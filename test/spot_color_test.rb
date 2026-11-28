# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pdf_objects"
require "prawn"

# Spot colours: a Separation colour space per ink, named on each page that paints with it, its tint as the operand.
class SpotColorTest < Minitest::Test
  def test_an_ink_is_one_separation_colour_space_painted_at_its_tint_on_every_page
    pdf = Prawn::Document.new do
      brand = spot_color("PANTONE 185 C", cmyk: [0, 91, 76, 0])
      fill_color brand
      fill_rectangle [0, 700], 100, 100
      fill_color spot_color("PANTONE 185 C", cmyk: [0, 91, 76, 0], tint: 0.4)
      fill_rectangle [120, 700], 100, 100
      stroke_color spot_color("Gold", rgb: "d4af37")
      stroke_rectangle [0, 560], 220, 80
      start_new_page
      fill_rectangle [0, 700], 100, 100
    end.render
    objects = PdfObjects.new(pdf)
    spaces = objects.pages.map { |page| objects.value(objects.value(page)["/Resources"])["/ColorSpace"].transform_values { objects.value(_1) } }

    ink = spaces.first.fetch("/CS0")
    assert_equal ["/Separation", "/PANTONE 185 C", "/DeviceCMYK"], ink.first(3)
    assert_equal [[0, 0, 0, 0], [0, 0.91, 0.76, 0]], objects.value(ink[3]).values_at("/C0", "/C1")
    assert_equal ["/Separation", "/Gold", "/DeviceRGB"], spaces.first.fetch("/CS1").first(3)
    assert_equal %w[/CS0 /CS1], spaces.last.keys.sort
    assert_equal ["/CS0 cs", "1.0 scn", "0.4 scn", "/CS1 CS", "1.0 SCN"], objects.content(objects.pages.first).lines.map(&:strip).grep(/ (?:cs|scn|CS|SCN)\z/).last(5)
    assert_includes objects.content(objects.pages.last), "/CS0 cs\n0.4 scn"
  end

  def test_the_native_api_takes_a_spot_colour_wherever_it_takes_a_colour
    document = Gamba.document
    red = document.spot_color("PANTONE 185 C", cmyk: [0, 91, 76, 0])
    document.stack(background: red, padding: 6) { _1.text "alice", color: red }

    assert_includes PdfObjects.new(document.to_s).content(PdfObjects.new(document.to_s).pages.first), "/CS0 cs"
  end

  def test_what_an_ink_cannot_be_raises
    document = Prawn::Document.new
    document.fill_color document.spot_color("Gold", rgb: "d4af37")

    assert_raises(ArgumentError) { document.fill_color document.spot_color("Gold", rgb: "ffd700") }
    assert_raises(ArgumentError) { document.spot_color("Gold") }
    assert_raises(ArgumentError) { document.spot_color("Gold", rgb: "d4af37", cmyk: [0, 10, 80, 10]) }
    assert_raises(ArgumentError) { document.spot_color("Gold", rgb: "d4af37", tint: 1.5) }
    assert_raises(ArgumentError) { document.spot_color("", rgb: "d4af37") }
    assert_raises(ArgumentError) { document.fill_gradient [0, 0], [10, 0], document.spot_color("Gold", rgb: "d4af37"), "000000" }
    pdf_a = Prawn::Document.new(pdf_a: true)
    assert_raises(Prawn::Errors::PdfAViolation) { pdf_a.fill_color pdf_a.spot_color("PANTONE 185 C", cmyk: [0, 91, 76, 0]) }
    pdf_a.fill_color pdf_a.spot_color("Gold", rgb: "d4af37")
  end
end
