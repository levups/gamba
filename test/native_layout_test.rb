# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# Stacks and rows of Gamba's own API: boxes measured, then placed, with pages broken between a stack's children.
class NativeLayoutTest < Minitest::Test
  PARAGRAPHS = Array.new(30) { |index| "Paragraph #{index} #{"word " * 60}".strip }

  def test_a_stack_of_texts_without_widow_or_orphan_rules_draws_what_prawn_text_calls_draw_across_pages
    native = Gamba.document { |document| document.stack { |stack| PARAGRAPHS.each { |paragraph| stack.text paragraph, size: 10, widows: 1, orphans: 1 } } }
    prawn = Prawn::Document.new { PARAGRAPHS.each { |paragraph| text paragraph, size: 10 } }

    assert_operator native.prawn.page_count, :>, 1
    assert_equal pages(prawn.render), pages(native.to_s)
    assert_in_delta prawn.cursor, native.prawn.cursor, 0.001
  end

  def test_a_stack_separates_its_children_by_its_gap_and_insets_them_by_its_padding
    y_after = nil
    document = Gamba.document(margin: 50) do |yielded|
      yielded.stack(gap: 10, padding: [5, 20]) do |stack|
        stack.text "A"
        stack.text "B"
      end
      y_after = yielded.prawn.y
    end
    first, second = glyphs(document.to_s)
    line_advance = Prawn::Document.new.height_of("A")

    assert_in_delta 70, first[3], 0.01
    assert_in_delta line_advance + 10, second[4] - first[4], 0.01
    assert_in_delta 792 - 50 - 5 - (2 * line_advance) - 10 - 5, y_after, 0.01
  end

  def test_a_row_gives_children_their_width_and_shares_the_rest_by_grow
    document = Gamba.document(margin: 50, page_size: [600, 400]) do |yielded|
      yielded.row(gap: 10) do |row|
        row.text "A", width: 100
        row.text "B"
        row.text "C", grow: 2
      end
    end

    assert_equal [50.0, 160.0, 296.67], glyphs(document.to_s).map { _1[3] }
  end

  def test_a_row_is_as_high_as_its_tallest_child
    document = Gamba.document do |yielded|
      yielded.row do |row|
        row.text "short"
        row.stack { |stack| 4.times { stack.text "line" } }
      end
      yielded.text "after"
    end
    after = glyphs(document.to_s).select { _1.first == "a" }.last
    first_line = glyphs(document.to_s).first

    assert_in_delta 4 * Prawn::Document.new.height_of("line"), after[4] - first_line[4], 0.01
  end

  def test_a_stack_kept_together_moves_whole_to_the_next_page
    kept, split = [true, false].map do |keep_together|
      Gamba.document do |document|
        document.prawn.move_down 660
        document.stack(keep_together:) { |stack| 6.times { |index| stack.text "line #{index}" } }
      end
    end

    assert_equal [0, 6], lines_by_page(kept.to_s)
    assert_equal [4, 2], lines_by_page(split.to_s)
  end

  def test_a_row_moves_whole_to_the_next_page
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 700
      yielded.row { |row| 2.times { row.text "word " * 30 } }
    end

    assert_equal [0, 4], lines_by_page(document.to_s)
  end

  def test_the_gap_is_dropped_at_the_top_of_a_page
    document = Gamba.document(margin: 50) do |yielded|
      yielded.prawn.move_down 680
      yielded.stack(gap: 40) { |stack| 2.times { stack.text "line" } }
    end
    first_page, second_page = pages(document.to_s)
    top_of_a_page = pages(Gamba.document(margin: 50) { |yielded| yielded.text "line" }.to_s).first.first[4]

    assert_equal 4, first_page.size
    assert_in_delta top_of_a_page, second_page.first[4], 0.01
  end

  def test_a_background_and_a_border_are_drawn_around_the_whole_box
    plain = Gamba.document { |document| document.stack(padding: 10) { |stack| stack.text "A" } }
    decorated = Gamba.document { |document| document.stack(padding: 10, background: "eeeeee", border_color: "ff0000", border_width: 2) { |stack| stack.text "A" } }
    rectangle = /^36\.0 722\.128 540\.0 33\.872 re$/

    assert_equal 0, uncompressed(plain.to_s).scan(rectangle).size
    assert_equal 2, uncompressed(decorated.to_s).scan(rectangle).size
    assert_equal glyphs(plain.to_s), glyphs(decorated.to_s)
  end

  def test_a_decorated_stack_splits_across_pages_drawn_around_each_part_with_its_padding
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 640
      yielded.stack(padding: 10, background: "eeeeee", border_color: "ff0000") do |stack|
        stack.text "line 0", color: "0000ff"
        5.times { |index| stack.text "line #{index + 1}" }
      end
    end
    first_page, second_page = pages(document.to_s)
    contents = page_contents(document.to_s)

    assert_equal [4, 2], lines_by_page(document.to_s)
    # Each part reaches the page's margin where the stack is cut, and keeps the padding clear on either side.
    assert_equal 2, contents[0].scan(/^36\.0 36\.0 540\.0 80\.0 re$/).size
    assert_equal 2, contents[1].scan(/^36\.0 708\.256 540\.0 47\.744 re$/).size
    assert_operator 792 - first_page.last[4] - 36, :>=, 10
    assert_in_delta second_page.first[4], 36 + 10 + Prawn::Document.new.font.ascender, 0.01
    # Each part is drawn under the text, in the colour space of the page where it starts.
    contents.each { |content| assert_operator content.index(" re\n"), :<, content.index("BT") }
    assert_nil with_file(document.to_s) { |path| Oracle.invalidity(path) }
  end

  def test_a_decorated_stack_kept_together_moves_whole_to_the_next_page
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 660
      yielded.stack(background: "eeeeee", keep_together: true) { |stack| 6.times { |index| stack.text "line #{index}" } }
    end

    assert_equal [0, 6], lines_by_page(document.to_s)
  end

  def test_nested_decorated_stacks_and_tables_split_inside_a_decorated_stack
    document = Gamba.document do |yielded|
      yielded.stack(padding: 12, border_color: "ff0000") do |outer|
        outer.stack(padding: 6, background: "ccddff") { |inner| 30.times { |index| inner.text "inner #{index}" } }
        outer.table(Array.new(60) { |index| {name: "row #{index}"} })
      end
    end
    pages = pages(document.to_s)

    assert_equal 3, pages.size
    pages.each do |glyphs|
      # Positions from the top: no line enters the outer stack's padding at either end of a page.
      assert_operator glyphs.map(&:last).max, :<=, 792 - 36 - 12
      assert_operator glyphs.map(&:last).min, :>=, 36 + 12
    end
    assert_nil with_file(document.to_s) { |path| Oracle.invalidity(path) }
  end

  def test_a_box_that_cannot_be_split_and_is_higher_than_a_page_raises
    error = assert_raises(Prawn::Errors::CannotFit) do
      Gamba.document { |document| document.row { |row| row.text "word " * 5000 } }
    end

    assert_match(/\Aa row is [\d.]+ pt high, the page has 720\.0 pt: it cannot be split\z/, error.message)
  end

  def test_children_wider_than_their_row_raise
    error = assert_raises(Prawn::Errors::CannotFit) do
      Gamba.document { |document| document.row(gap: 10) { |row| 2.times { row.text "A", width: 300 } } }
    end

    assert_equal "a row's children are 70.0 pt wider than the row", error.message
  end

  def test_unknown_or_contradictory_options_raise
    document = Gamba.document

    assert_match(/\Aunknown option :gab: accepted options are :width, :grow, :keep_with_next, :gap, /, assert_raises(ArgumentError) { document.stack(gab: 2) { nil } }.message)
    assert_raises(ArgumentError) { document.row(keep_together: true) { nil } }
    assert_raises(ArgumentError) { document.stack(padding: [1, 2, 3]) { nil } }
    assert_raises(ArgumentError) { document.row { |row| row.text "A", width: 10, grow: 1 } }
    assert_raises(ArgumentError) { document.stack { |stack| stack.text "A", grow: 1 } }
    assert_raises(ArgumentError) { document.stack { |stack| stack.text "A", colour: "ff0000" } }
    assert_raises(ArgumentError) { document.stack { |stack| stack.text "A", style: :missing } }
  end

  def test_styles_apply_inside_boxes
    document = Gamba.document do |yielded|
      yielded.style :default, font: "Courier", size: 10
      yielded.style :title, size: 18, weight: :bold
      yielded.row do |row|
        row.text "A", style: :title
        row.stack { |stack| stack.text "B", italic: true }
      end
    end

    assert_equal [["A", "Courier-Bold", 18.0], ["B", "Courier-Oblique", 10.0]], glyphs(document.to_s).map { _1.first(3) }
  end

  def test_a_component_drawn_in_a_box_receives_the_box
    address = ->(builder) { builder.text "1 Example Street" }
    document = Gamba.document do |yielded|
      yielded.row do |row|
        row.text "Alice"
        row.draw address
      end
    end

    assert_equal 2, glyphs(document.to_s).map { _1[3] }.uniq.count { |x| [36.0, 306.0].include?(x) }
    assert_equal 1, lines_by_page(document.to_s).first
  end

  def test_a_box_in_prawn_code_starts_at_the_cursor_within_the_bounds_and_leaves_the_cursor_below
    cursor_after = nil
    pdf = Prawn::Document.new do
      text "Before"
      bounding_box([100, cursor], width: 200) do
        gamba { |document| document.row { |row| 2.times { row.text "cell" } } }
      end
      cursor_after = cursor
      text "After"
    end
    before, *cells, after = glyphs(pdf.render).select { ["B", "c", "A"].include?(_1.first) }
    line_advance = pdf.height_of("cell")

    assert_equal [136.0, 236.0], cells.map { _1[3] }
    assert_in_delta 720 - (2 * line_advance), cursor_after, 0.01
    assert_in_delta 2 * line_advance, after[4] - before[4], 0.01
  end

  def test_a_laid_out_document_is_a_valid_pdf_rendered_the_same_twice
    render = lambda do
      Gamba.document do |document|
        document.row(gap: 12, padding: 8, background: "eeeeee", border_color: "999999") do |row|
          row.stack(gap: 4) { |stack| PARAGRAPHS.first(3).each { |paragraph| stack.text paragraph } }
          row.text "Due 2026-12-01", width: 120, align: :right
        end
        document.stack(gap: 6) { |stack| PARAGRAPHS.each { |paragraph| stack.text paragraph } }
      end.to_s
    end
    pdf = render.call

    assert_equal pdf, render.call
    Tempfile.create(["layout", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush

      assert_nil Oracle.invalidity(file.path)
    end
  end

  private

  def lines_by_page(pdf)
    pages(pdf).map { |page| page.map(&:last).uniq.size }
  end

  def glyphs(pdf)
    pages(pdf).flatten(1)
  end

  def pages(pdf)
    with_file(pdf) { |path| Oracle.text_layout(path).map(&:glyphs) }
  end

  def page_contents(pdf)
    uncompressed(pdf).split("%% Contents for page ").drop(1)
  end

  def uncompressed(pdf)
    with_file(pdf) { |path| Open3.capture2("qpdf", "--qdf", "--object-streams=disable", path, "-").first.b }
  end

  def with_file(pdf)
    Tempfile.create(["layout", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      yield file.path
    end
  end
end
