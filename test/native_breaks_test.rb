# frozen_string_literal: true

require_relative "test_helper"
require "prawn"

# Where pages break in Gamba's own API: no paragraph leaves fewer than `orphans` lines at the bottom of a page nor
# fewer than `widows` at the top of the next, and a box kept with the next one starts the same page as it.
class NativeBreaksTest < Minitest::Test
  # Helvetica at 12 pt: a line ends 11.1 pt below where it starts, and the next one starts 13.872 pt lower.
  FIRST_LINE_POINTS = 11.1
  LINE_ADVANCE = 13.872
  PAGE_POINTS = 720

  def test_a_paragraph_that_would_leave_an_orphan_moves_to_the_next_page
    assert_equal [[], 5], lines_by_page { |document| room_for(document, 1).text(paragraph(5)) }
    assert_equal [1, 4], lines_by_page { |document| room_for(document, 1).text(paragraph(5), orphans: 1) }
  end

  def test_a_paragraph_that_would_leave_a_widow_gives_the_next_page_enough_lines
    assert_equal [3, 2], lines_by_page { |document| room_for(document, 4).text(paragraph(5)) }
    assert_equal [2, 3], lines_by_page { |document| room_for(document, 4).text(paragraph(5), widows: 3) }
    assert_equal [4, 1], lines_by_page { |document| room_for(document, 4).text(paragraph(5), widows: 1) }
  end

  def test_a_paragraph_too_short_to_satisfy_both_rules_moves_whole
    assert_equal [[], 3], lines_by_page { |document| room_for(document, 2).text(paragraph(3)) }
  end

  def test_a_paragraph_longer_than_a_page_still_fills_each_page_it_starts
    pages = lines_by_page { |document| document.text(paragraph(120)) }

    assert_equal 120, pages.sum
    assert_equal ((PAGE_POINTS - FIRST_LINE_POINTS) / LINE_ADVANCE).floor + 1, pages.first
  end

  def test_rules_apply_to_text_in_stacks_and_can_come_from_a_style
    assert_equal [[], 5], lines_by_page { |document| room_for(document, 1).stack { |stack| stack.text paragraph(5) } }
    pages = lines_by_page do |document|
      document.style :body, widows: 3
      room_for(document, 4).stack { |stack| stack.text paragraph(5), style: :body }
    end

    assert_equal [2, 3], pages
  end

  def test_a_box_kept_with_the_next_goes_to_the_next_page_with_the_start_of_it
    kept = texts_by_page do |document|
      room_for(document, 2).stack do |stack|
        stack.text "Title", keep_with_next: true
        stack.text paragraph(5)
      end
    end
    loose = texts_by_page do |document|
      room_for(document, 2).stack do |stack|
        stack.text "Title"
        stack.text paragraph(5)
      end
    end

    assert_equal ["", "Title#{(1..5).map { "line #{_1}" }.join}"], kept
    assert_equal "Title", loose.first
  end

  def test_a_box_kept_with_the_next_stays_when_the_start_of_the_next_fits
    pages = texts_by_page do |document|
      room_for(document, 3).stack do |stack|
        stack.text "Title", keep_with_next: true
        stack.text paragraph(5)
      end
    end

    assert_equal "Titleline 1line 2", pages.first
  end

  def test_boxes_kept_with_the_next_on_the_document_and_through_a_style_wait_for_it
    pages = texts_by_page do |document|
      document.style :heading, weight: :bold, keep_with_next: true
      room_for(document, 3)
      document.text "Chapter", style: :heading
      document.text "Section", style: :heading
      document.text paragraph(5)
    end

    assert_equal ["", "ChapterSection#{(1..5).map { "line #{_1}" }.join}"], pages
  end

  def test_a_title_kept_with_a_table_needs_room_for_its_header_and_first_row
    rows = Array.new(3) { |index| {item: "row #{index}"} }
    pages = texts_by_page do |document|
      room_for(document, 2)
      document.text "Title", keep_with_next: true
      document.table(rows)
    end

    assert_equal "", pages.first
    assert pages.last.start_with?("TitleItemrow 0")
  end

  def test_a_kept_box_with_nothing_after_it_is_placed_before_what_prawn_draws_next
    pages = texts_by_page do |document|
      document.text "Kept", keep_with_next: true
      document.prawn.text "From Prawn"
    end
    bridged = Prawn::Document.new do
      gamba { |document| document.text "Kept", keep_with_next: true }
      text "From Prawn"
    end

    assert_equal ["KeptFrom Prawn"], pages
    assert_equal ["KeptFrom Prawn"], texts(bridged.render)
    assert_equal ["Last"], texts_by_page { |document| document.text "Last", keep_with_next: true }
  end

  def test_boxes_kept_together_higher_than_a_page_break_as_they_would_without
    pages = lines_by_page do |document|
      room_for(document, 3).stack do |stack|
        stack.text paragraph(60), keep_with_next: true
        stack.text paragraph(2)
      end
    end

    assert_equal 62, pages.sum
    assert_equal 3, pages.first
  end

  def test_a_table_kept_with_the_next_moves_with_the_start_of_it
    rows = [{item: "row"}]
    kept, loose = [true, false].map do |keep_with_next|
      texts_by_page do |document|
        room_for(document, 3)
        document.table(rows, header: false, keep_with_next:)
        document.text paragraph(5)
      end
    end

    assert_equal "", kept.first
    assert kept.last.start_with?("rowline 1")
    assert_equal "row", loose.first
  end

  def test_a_page_break_starts_what_follows_on_a_new_page_after_the_boxes_waiting_for_it
    pages = texts_by_page do |document|
      document.text "Kept", keep_with_next: true
      document.page_break
      document.text "Next page"
    end

    assert_equal ["Kept", "Next page"], pages
  end

  def test_widows_and_orphans_take_a_number_of_lines
    document = Gamba.document

    assert_equal "widows is 0: give a number of lines, 1 or more", assert_raises(ArgumentError) { document.text "A", widows: 0 }.message
    assert_raises(ArgumentError) { document.text "A", orphans: "2" }
    document.style :body, orphans: 1.5

    assert_raises(ArgumentError) { document.text "A", style: :body }
  end

  private

  def paragraph(lines)
    (1..lines).map { "line #{_1}" }.join("\n")
  end

  # Leaves room on the first page for `lines` lines of 12 pt Helvetica and a few points more, not for one more.
  def room_for(document, lines)
    document.prawn.move_down(PAGE_POINTS - (FIRST_LINE_POINTS + ((lines - 1) * LINE_ADVANCE) + 5))
    document
  end

  def lines_by_page(&)
    pages(Gamba.document(&).to_s).map { |page| page.map(&:last).uniq.size }.map { _1.zero? ? [] : _1 }
  end

  def texts_by_page(&)
    texts(Gamba.document(&).to_s)
  end

  def texts(pdf)
    pages(pdf).map { |page| page.map(&:first).join }
  end

  # In reading order: mutool measures y down from the top of the page.
  def pages(pdf)
    Tempfile.create(["breaks", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Oracle.text_layout(file.path).map { |page| page.glyphs.sort_by { |glyph| [glyph[4], glyph[3]] } }
    end
  end
end
