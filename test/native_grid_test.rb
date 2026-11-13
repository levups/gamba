# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# Grids of Gamba's own API: cells in lines of a given number of equal columns, pages broken between lines.
class NativeGridTest < Minitest::Test
  def test_cells_take_equal_columns_the_last_line_included_and_lines_are_separated_by_the_line_gap
    document = Gamba.document(margin: 50, page_size: [600, 400]) do |yielded|
      yielded.grid(columns: 3, gap: [20, 10]) { |grid| %w[A B C D].each { |letter| grid.text letter } }
    end
    a, b, c, d = glyphs(document.to_s)

    assert_equal [50.0, 220.0, 390.0, 50.0], [a, b, c, d].map { _1[3] }
    assert_equal [a[4]] * 3, [a, b, c].map { _1[4] }
    assert_in_delta line_advance + 20, d[4] - a[4], 0.01
  end

  def test_one_gap_separates_both_lines_and_columns
    document = Gamba.document(margin: 50, page_size: [600, 400]) do |yielded|
      yielded.grid(columns: 2, gap: 10) { |grid| %w[A B C].each { |letter| grid.text letter } }
    end
    a, b, c = glyphs(document.to_s)

    assert_equal [50.0, 305.0, 50.0], [a, b, c].map { _1[3] }
    assert_in_delta line_advance + 10, c[4] - a[4], 0.01
  end

  def test_a_line_is_as_high_as_its_tallest_cell
    document = Gamba.document do |yielded|
      yielded.grid(columns: 2) do |grid|
        grid.text "short"
        grid.stack { |stack| 4.times { stack.text "line" } }
        grid.text "next"
      end
    end
    first, next_line = glyphs(document.to_s).values_at(0, -4)

    assert_equal "n", next_line.first
    assert_in_delta 4 * line_advance, next_line[4] - first[4], 0.01
  end

  def test_cells_with_a_background_or_a_border_are_drawn_as_high_as_their_line
    document = Gamba.document do |yielded|
      yielded.grid(columns: 3) do |grid|
        grid.stack(border_color: "cccccc") { |card| card.text "short" }
        grid.stack(background: "eeeeee") { |card| 3.times { card.text "tall" } }
        grid.text "plain"
      end
    end
    heights = uncompressed(document.to_s).scan(/^[\d.]+ [\d.]+ [\d.]+ ([\d.]+) re$/).flatten.map(&:to_f)

    assert_equal 2, heights.size
    assert_in_delta 3 * line_advance, heights.first, 0.01
    assert_equal heights.first, heights.last
  end

  def test_pages_break_between_lines_never_inside_one
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 700
      yielded.grid(columns: 2) { |grid| 4.times { |index| grid.text "cell #{index}" } }
    end

    assert_equal [1, 1], lines_by_page(document.to_s)
  end

  def test_a_line_with_a_cell_kept_with_the_next_goes_to_the_next_page_with_it
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 700
      yielded.grid(columns: 2) do |grid|
        grid.text "heading", keep_with_next: true
        grid.text "aside"
        2.times { |index| grid.text "cell #{index}" }
      end
    end

    assert_equal [0, 2], lines_by_page(document.to_s)
  end

  def test_a_decorated_grid_breaks_between_its_lines_unless_kept_together
    split = Gamba.document do |yielded|
      yielded.prawn.move_down 700
      yielded.grid(columns: 2, background: "eeeeee") { |grid| 4.times { |index| grid.text "cell #{index}" } }
    end
    kept = Gamba.document do |yielded|
      yielded.prawn.move_down 700
      yielded.grid(columns: 2, background: "eeeeee", keep_together: true) { |grid| 4.times { |index| grid.text "cell #{index}" } }
    end

    assert_equal [1, 1], lines_by_page(split.to_s)
    assert_equal [0, 2], lines_by_page(kept.to_s)
  end

  def test_a_grid_is_a_box_like_the_others
    document = Gamba.document(margin: 50, page_size: [600, 400]) do |yielded|
      yielded.row(gap: 20) do |row|
        row.text "L", width: 100
        row.grid(columns: 2, padding: 10) { |grid| %w[A B].each { |letter| grid.text letter } }
      end
    end

    assert_equal [50.0, 180.0, 360.0], glyphs(document.to_s).map { _1[3] }.uniq
  end

  def test_wrong_columns_gaps_and_cell_widths_raise
    document = Gamba.document

    assert_raises(ArgumentError) { document.grid { nil } }
    assert_match(/\Acolumns is 0: /, assert_raises(ArgumentError) { document.grid(columns: 0) { nil } }.message)
    assert_raises(ArgumentError) { document.grid(columns: "2") { nil } }
    assert_raises(ArgumentError) { document.grid(columns: 2, gap: [1, 2, 3]) { nil } }
    assert_match(/\Aunknown option :rows: accepted options are :width, :grow, .*:keep_together, :columns\z/, assert_raises(ArgumentError) { document.grid(columns: 2, rows: 2) { nil } }.message)
    assert_raises(ArgumentError) { document.grid(columns: 2) { |grid| grid.text "A", width: 10 } }
    assert_raises(ArgumentError) { document.grid(columns: 2) { |grid| grid.text "A", grow: 1 } }
    assert_equal "a grid's gaps are 60.0 pt wider than the grid", assert_raises(Prawn::Errors::CannotFit) { document.grid(columns: 4, gap: 200) { |grid| grid.text "A" } }.message
  end

  private

  def line_advance
    Prawn::Document.new.height_of("A")
  end

  def lines_by_page(pdf)
    pages(pdf).map { |page| page.map(&:last).uniq.size }
  end

  def glyphs(pdf)
    pages(pdf).flatten(1)
  end

  def pages(pdf)
    with_file(pdf) { |path| Oracle.text_layout(path).map(&:glyphs) }
  end

  def uncompressed(pdf)
    with_file(pdf) { |path| Open3.capture2("qpdf", "--qdf", "--object-streams=disable", path, "-").first.b }
  end

  def with_file(pdf)
    Tempfile.create(["grid", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      yield file.path
    end
  end
end
