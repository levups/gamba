# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# Tables and images as boxes of Gamba's own API: measured like the others, placed in stacks and rows.
class NativeBoxesTest < Minitest::Test
  IMAGE = File.join(Oracle::ROOT, "corpus/cache/prawn/data/images/dice.png") # 320 by 240 points
  LINES = Array.new(60) { |index| {sku: "SKU#{index}", description: "Gadget, model #{index}", quantity: 2} }.freeze
  COLUMNS = {sku: {title: "SKU"}, description: {}, quantity: {align: :right}}.freeze
  Line = Data.define(:sku, :quantity)

  def test_a_table_draws_what_prawn_draws_at_the_width_of_its_box_across_pages
    native = Gamba.document { |document| document.table(LINES, columns: COLUMNS, cell: {size: 9}) }
    prawn = Prawn::Document.new do
      table([%w[SKU Description Quantity], *LINES.map(&:values)], header: true, width: bounds.width, cell_style: {size: 9}) do
        column(2).align = :right
        row(0).font_style = :bold
      end
    end

    assert_operator native.prawn.page_count, :>, 1
    assert_equal pages(prawn.render), pages(native.to_s)
    assert_in_delta prawn.cursor, native.prawn.cursor, 0.001
  end

  def test_columns_are_those_of_the_first_row_unless_named_and_titles_come_from_their_names
    document = Gamba.document { |yielded| yielded.table([{first_name: "Alice", city: "Paris"}]) }

    assert_equal "First nameCityAliceParis", glyphs(document.to_s).map(&:first).join
  end

  def test_rows_can_be_objects_answering_the_names_of_the_columns
    document = Gamba.document { |yielded| yielded.table([Line.new(sku: "A-1", quantity: 2)], columns: {quantity: {title: "Qty"}, sku: {title: "SKU"}}) }

    assert_equal "QtySKU2A-1", glyphs(document.to_s).map(&:first).join
  end

  def test_a_column_takes_its_width_alignment_and_text_attributes
    document = Gamba.document do |yielded|
      yielded.table([{name: "A", amount: "B"}], header: false, columns: {name: {width: 100, italic: true, size: 9}, amount: {width: 50, align: :right, weight: :bold}})
    end
    name, amount = glyphs(document.to_s)

    assert_equal [["A", "Helvetica-Oblique", 9.0, 41.0], ["B", "Helvetica-Bold", 12.0]], [name.first(4), amount.first(3)]
    assert_equal prawn_right_aligned_bold_x, amount[3]
  end

  def test_the_header_is_bold_unless_styled_and_can_be_left_out
    fonts = lambda do |header|
      document = Gamba.document { |yielded| yielded.table([{name: "A"}], header:) }
      glyphs(document.to_s).map { [_1[0], _1[1], _1[2]] }.uniq
    end

    assert_equal [["N", "Helvetica-Bold", 12.0], ["a", "Helvetica-Bold", 12.0], ["m", "Helvetica-Bold", 12.0], ["e", "Helvetica-Bold", 12.0], ["A", "Helvetica", 12.0]], fonts.call(true)
    assert_equal [["A", "Helvetica", 12.0]], fonts.call(false)
    assert_equal ["Helvetica-BoldOblique", 9.0], fonts.call({italic: true, size: 9}).first.last(2)
  end

  def test_stripes_the_header_background_and_cell_options_reach_the_cells
    document = Gamba.document do |yielded|
      yielded.table(LINES.first(3), columns: COLUMNS, stripes: %w[ffffff eeeeee], header: {background: "333333", color: "ffffff"}, cell: {padding: 2, border_color: "ff0000"})
    end
    content = uncompressed(document.to_s)

    assert_includes content, "0.2 0.2 0.2 scn"
    assert_includes content, "0.93333 0.93333 0.93333 scn"
    assert_includes content, "1.0 0.0 0.0 SCN"
    assert_in_delta 38, glyphs(document.to_s).first[3], 0.01
  end

  def test_cells_start_from_the_default_style_and_the_cell_option_wins
    document = Gamba.document do |yielded|
      yielded.style :default, font: "Courier", size: 9, color: "336699"
      yielded.table([{name: "A"}], header: false)
      yielded.table([{name: "B"}], header: false, cell: {size: 14, font: "Times-Roman"})
    end

    assert_equal [["A", "Courier", 9.0], ["B", "Times-Roman", 14.0]], glyphs(document.to_s).map { _1.first(3) }
    assert_includes uncompressed(document.to_s), "0.2 0.4 0.6 scn"
  end

  def test_the_block_receives_the_prawn_table_before_it_is_laid_out
    document = Gamba.document do |yielded|
      yielded.table([{name: "A"}], header: false) do |table|
        assert_instance_of Prawn::Table, table
        table.cells[0, 0].font_style = :italic
      end
    end

    assert_equal ["Helvetica-Oblique"], glyphs(document.to_s).map { _1[1] }
  end

  def test_a_table_without_a_header_or_a_row_draws_nothing_and_takes_no_room
    cursor_after = nil
    document = Gamba.document do |yielded|
      yielded.stack(gap: 10) { |stack| stack.table([], columns: COLUMNS, header: false) }
      cursor_after = yielded.prawn.cursor
    end

    assert_in_delta 720, cursor_after, 0.001
    assert_empty glyphs(document.to_s)
  end

  def test_what_follows_a_table_in_a_stack_starts_below_it_after_the_gap
    document = Gamba.document do |yielded|
      yielded.stack(gap: 10) do |stack|
        stack.table(LINES.first(2), columns: COLUMNS, header: false)
        stack.text "After"
      end
    end
    table_height = Prawn::Document.new.make_table(LINES.first(2).map(&:values)).height
    after = glyphs(document.to_s).find { _1.first == "A" }
    top_of_a_page = glyphs(Gamba.document { |yielded| yielded.text "After" }.to_s).first[4]

    assert_in_delta top_of_a_page + table_height + 10, after[4], 0.01
  end

  def test_a_table_in_a_row_takes_its_share_and_sets_the_height_of_the_row
    cursor_after = nil
    document = Gamba.document do |yielded|
      yielded.row(gap: 20) do |row|
        row.text "Left"
        row.table([{first: "A", second: "B"}, {first: "C", second: "D"}], header: false, width: 200)
      end
      cursor_after = yielded.prawn.cursor
    end
    table_height = Prawn::Document.new.make_table([%w[A B], %w[C D]]).height

    assert_in_delta 36 + 540 - 200 + 5, glyphs(document.to_s).find { _1.first == "A" }[3], 0.01
    assert_in_delta 720 - table_height, cursor_after, 0.01
  end

  def test_a_row_holding_a_table_moves_whole_to_the_next_page
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 690
      yielded.row do |row|
        row.text "Left"
        row.table(LINES.first(3), columns: COLUMNS)
      end
    end
    first_page, second_page = pages(document.to_s).map { |page| page.map(&:first).join }

    assert_empty first_page
    assert_includes second_page, "Left"
    assert_includes second_page, "SKU1"
  end

  def test_a_table_that_fills_the_page_to_the_point_is_not_cut
    table_height = Prawn::Document.new.make_table(LINES.first(3).map(&:values), width: 540).height
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 720 - table_height
      yielded.row { |row| row.table(LINES.first(3), columns: COLUMNS, header: false) }
    end

    assert_equal [0, 3], lines_by_page(document.to_s)
  end

  def test_a_table_row_higher_than_a_page_raises_instead_of_running_past_the_bottom
    error = assert_raises(Prawn::Errors::CannotFit) do
      Gamba.document(page_size: [400, 300]) do |document|
        document.stack(width: 60) { |stack| stack.table([{name: "alice " * 40, quantity: 1}]) }
      end
    end

    assert_match(/\Aa table has a row [\d.]+ pt high under a [\d.]+ pt header, the page has 228\.0 pt\z/, error.message)
  end

  def test_rows_as_arrays_missing_columns_and_unknown_options_raise
    document = Gamba.document

    assert_match(/\Acolumns are missing: name them, /, assert_raises(ArgumentError) { document.table([%w[A B]]) }.message)
    assert_match(/\Aa row is an array: rows are hashes, /, assert_raises(ArgumentError) { document.table([%w[A B]], columns: COLUMNS) }.message)
    assert_match(/\Aunknown option :titel: accepted options are :title, :width, /, assert_raises(ArgumentError) { document.table(LINES, columns: {sku: {titel: "SKU"}}) }.message)
    assert_raises(ArgumentError) { document.table(LINES, cell: {paddin: 2}) }
    assert_raises(ArgumentError) { document.table(LINES, header: {weigth: :bold}) }
    assert_raises(ArgumentError) { document.table(LINES, columns: {}) }
    assert_raises(ArgumentError) { document.table(LINES, columns: {sku: {weight: :heavy}}) }
  end

  def test_unknown_table_and_image_options_raise
    document = Gamba.document

    assert_match(/\Aunknown option :headr: accepted options are :width, :grow, :keep_with_next, :columns, :header, :stripes, :cell\z/, assert_raises(ArgumentError) { document.table(LINES, headr: true) }.message)
    assert_raises(ArgumentError) { document.image(IMAGE, hight: 40) }
    assert_raises(ArgumentError) { document.image(IMAGE, align: :middle) }
    assert_raises(ArgumentError) { document.image(IMAGE, grow: 1) }
    assert_raises(ArgumentError) { document.image("missing.png") }
  end

  def test_an_image_keeps_its_size_unless_told_a_width_or_a_height_and_its_proportions_always
    skip CORPUS_MISSING_MESSAGE unless File.exist?(IMAGE)

    assert_equal [[320.0, 240.0, 36.0, 516.0]], placements(Gamba.document { |document| document.image IMAGE })
    assert_equal [[120.0, 90.0, 36.0, 666.0]], placements(Gamba.document { |document| document.image IMAGE, width: 120 })
    assert_equal [[80.0, 60.0, 36.0, 696.0]], placements(Gamba.document { |document| document.image IMAGE, height: 60 })
  end

  def test_an_image_is_never_wider_than_its_box_and_is_aligned_in_it
    skip CORPUS_MISSING_MESSAGE unless File.exist?(IMAGE)
    document = Gamba.document(page_size: [372, 400]) do |yielded|
      yielded.row(gap: 0) do |row|
        row.image IMAGE
        row.image IMAGE, height: 30, align: :center
        row.image IMAGE, height: 30, align: :right
      end
    end

    assert_equal [[100.0, 75.0, 36.0, 289.0], [40.0, 30.0, 166.0, 334.0], [40.0, 30.0, 296.0, 334.0]], placements(document)
  end

  def test_what_follows_an_image_starts_below_it_and_an_image_too_high_for_the_page_moves_to_the_next
    skip CORPUS_MISSING_MESSAGE unless File.exist?(IMAGE)
    cursors = []
    document = Gamba.document do |yielded|
      yielded.image IMAGE, height: 100
      cursors << yielded.prawn.cursor
      yielded.prawn.move_down 600
      yielded.image IMAGE, height: 100
      cursors << yielded.prawn.cursor
    end

    assert_equal [620.0, 620.0], cursors
    assert_equal 2, document.prawn.page_count
  end

  def test_an_image_placed_twice_is_embedded_once
    skip CORPUS_MISSING_MESSAGE unless File.exist?(IMAGE)
    document = Gamba.document { |yielded| yielded.row { |row| 2.times { row.image IMAGE, height: 40 } } }

    assert_equal 2, placements(document).size
    assert_equal 1, uncompressed(document.to_s).scan(%r{/Subtype /Image}).size - uncompressed(document.to_s).scan(%r{/SMask \d}).size
  end

  private

  # Where Prawn's own table draws the same cell: its right alignment is what the native table must match.
  def prawn_right_aligned_bold_x
    prawn = Prawn::Document.new { table([%w[A B]], column_widths: {0 => 100, 1 => 50}) { column(1).style(align: :right, font_style: :bold) } }
    glyphs(prawn.render).last[3]
  end

  # Each image drawn: [width, height, left, bottom], from the matrix its `Do` operator is drawn with.
  def placements(document)
    uncompressed(document.to_s).scan(/^([\d.]+) 0\.0 0\.0 ([\d.]+) ([\d.]+) ([\d.]+) cm\n\/I\d+ Do$/).map { |numbers| numbers.map { _1.to_f.round(2) } }
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
    Tempfile.create(["boxes", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      yield file.path
    end
  end
end
