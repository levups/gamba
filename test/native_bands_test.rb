# frozen_string_literal: true

require_relative "test_helper"
require "prawn"

# Headers and footers of Gamba's own API: declared once, built for each page with its number and the total.
class NativeBandsTest < Minitest::Test
  PARAGRAPH = ("word " * 80).strip
  LINE_ADVANCE = 13.872 # Helvetica at 12 pt

  def test_a_header_and_a_footer_are_drawn_on_every_page_with_its_number_and_the_total
    document = Gamba.document do |yielded|
      yielded.header { |header, page| header.text "Report, page #{page.number}" }
      yielded.footer { |footer, page| footer.text "#{page.number}/#{page.total}", align: :right }
      yielded.stack { |stack| 30.times { stack.text PARAGRAPH } }
    end
    pages = texts_by_page(document.to_s)

    assert_equal 3, pages.size
    pages.each_with_index do |text, index|
      assert text.start_with?("Report, page #{index + 1}word"), text[0, 30]
      assert text.end_with?("word#{index + 1}/3"), text[-10..]
    end
  end

  def test_the_body_starts_below_the_header_and_its_gap_and_ends_above_the_footer_and_its_gap
    document = Gamba.document(margin: 50) do |yielded|
      yielded.header(gap: 20) { |header, _page| header.text "H" }
      yielded.footer(gap: 30) { |footer, _page| footer.text "F" }
      yielded.stack { |stack| 60.times { stack.text "b" } }
    end
    first_page, second_page = pages(document.to_s)
    header, first_body = first_page.first(2)
    last_body, footer = first_page.last(2)
    body_lines = ((792 - 100 - 20 - 30 - (2 * LINE_ADVANCE)) / LINE_ADVANCE).floor

    assert_equal %w[H b b F], [header, first_body, last_body, footer].map(&:first)
    assert_in_delta LINE_ADVANCE + 20, first_body[4] - header[4], 0.01
    assert_in_delta 792 - 100 - LINE_ADVANCE, footer[4] - header[4], 0.01
    assert_operator footer[4] - last_body[4], :>=, LINE_ADVANCE + 30
    assert_equal body_lines + 2, first_page.size
    assert_equal first_body[4], second_page[1][4]
  end

  def test_prawn_text_flows_between_the_header_and_the_footer_too
    pdf = Prawn::Document.new do
      gamba do |document|
        document.header(gap: 10) { |header, page| header.text "Header #{page.number}" }
        document.footer(gap: 10) { |footer, page| footer.text "Footer #{page.number} of #{page.total}" }
      end
      text ("word " * 80) * 30
    end
    pages = texts_by_page(pdf.render)

    assert_operator pages.size, :>, 2
    pages.each_with_index do |text, index|
      assert text.start_with?("Header #{index + 1}word")
      assert text.end_with?("wordFooter #{index + 1} of #{pages.size}")
    end
  end

  def test_a_header_starts_on_the_page_it_is_declared_on
    document = Gamba.document do |yielded|
      yielded.text "Cover"
      yielded.prawn.start_new_page
      yielded.header { |header, page| header.text "Header #{page.number}" }
      yielded.text "Body"
    end

    assert_equal ["Cover", "Header 2Body"], texts_by_page(document.to_s)
  end

  def test_a_table_in_a_footer_stays_on_its_page
    document = Gamba.document do |yielded|
      yielded.footer { |footer, page| footer.table([{label: "Page", number: page.number}], header: false) }
      yielded.text "Body"
    end

    assert_equal ["BodyPage1"], texts_by_page(document.to_s)
  end

  def test_a_header_higher_on_a_later_page_than_on_the_first_raises_at_render
    document = Gamba.document do |yielded|
      yielded.header { |header, page| page.number.times { header.text "line" } }
      yielded.prawn.start_new_page
    end
    error = assert_raises(Prawn::Errors::CannotFit) { document.to_s }

    assert_equal "the header is 27.7 pt high on page 2, 13.9 pt were kept for it, its height on the page it was declared on", error.message
  end

  def test_a_second_header_no_block_or_an_unknown_option_raises
    document = Gamba.document
    document.header { |header, _page| header.text "H" }

    assert_equal "the header is already declared: a document has one", assert_raises(ArgumentError) { document.header { nil } }.message
    assert_raises(ArgumentError) { document.footer }
    assert_raises(ArgumentError) { document.footer(gab: 2) { nil } }
  end

  private

  # In reading order, not in the order drawn: headers and footers are drawn last, once the pages are counted.
  def texts_by_page(pdf)
    pages(pdf).map { |page| page.map(&:first).join }
  end

  def pages(pdf)
    Tempfile.create(["bands", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Oracle.text_layout(file.path).map { |page| page.glyphs.sort_by { |glyph| [glyph[4], glyph[3]] } }
    end
  end
end
