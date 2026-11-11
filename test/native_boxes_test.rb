# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"

# Tables and images as boxes of Gamba's own API: measured like the others, placed in stacks and rows.
class NativeBoxesTest < Minitest::Test
  IMAGE = File.join(Oracle::ROOT, "corpus/cache/prawn/data/images/dice.png") # 320 by 240 points
  ROWS = [%w[SKU Description Quantity], *Array.new(60) { |index| ["SKU#{index}", "Gadget, model #{index}", "2"] }].freeze

  def test_a_table_draws_what_prawn_draws_at_the_width_of_its_box_across_pages
    native = Gamba.document { |document| document.table(ROWS, header: true, cell_style: {size: 9}) }
    prawn = Prawn::Document.new { table(ROWS, header: true, width: bounds.width, cell_style: {size: 9}) }

    assert_operator native.prawn.page_count, :>, 1
    assert_equal pages(prawn.render), pages(native.to_s)
    assert_in_delta prawn.cursor, native.prawn.cursor, 0.001
  end

  def test_the_block_styles_the_prawn_table_before_it_is_laid_out
    document = Gamba.document do |yielded|
      yielded.table(ROWS.first(2)) do |table|
        assert_instance_of Prawn::Table, table
        table.row(0).font_style = :bold
      end
    end

    assert_equal %w[Helvetica-Bold Helvetica], glyphs(document.to_s).map { _1[1] }.uniq
  end

  def test_a_table_given_all_its_column_widths_keeps_them
    document = Gamba.document { |yielded| yielded.table([%w[A B]], column_widths: [100, 50]) }

    assert_equal [41.0, 141.0], glyphs(document.to_s).map { _1[3] }
  end

  def test_what_follows_a_table_in_a_stack_starts_below_it_after_the_gap
    document = Gamba.document do |yielded|
      yielded.stack(gap: 10) do |stack|
        stack.table(ROWS.first(3))
        stack.text "After"
      end
    end
    table_height = Prawn::Document.new.make_table(ROWS.first(3)).height
    after = glyphs(document.to_s).find { _1.first == "A" }
    top_of_a_page = glyphs(Gamba.document { |yielded| yielded.text "After" }.to_s).first[4]

    assert_in_delta top_of_a_page + table_height + 10, after[4], 0.01
  end

  def test_a_table_in_a_row_takes_its_share_and_sets_the_height_of_the_row
    cursor_after = nil
    document = Gamba.document do |yielded|
      yielded.row(gap: 20) do |row|
        row.text "Left"
        row.table([%w[A B], %w[C D]], width: 200)
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
        row.table(ROWS.first(3))
      end
    end

    first_page, second_page = pages(document.to_s).map { |page| page.map(&:first).join }

    assert_empty first_page
    assert_includes second_page, "Left"
    assert_includes second_page, "SKU1"
  end

  def test_a_table_that_fills_the_page_to_the_point_is_not_cut
    table_height = Prawn::Document.new.make_table(ROWS.first(3), width: 540).height
    document = Gamba.document do |yielded|
      yielded.prawn.move_down 720 - table_height
      yielded.row { |row| row.table(ROWS.first(3)) }
    end

    assert_equal [0, 3], lines_by_page(document.to_s)
  end

  def test_unknown_table_and_image_options_raise
    document = Gamba.document

    assert_match(/\Aunknown option :headr: accepted options are :width, :grow, :header, /, assert_raises(ArgumentError) { document.table(ROWS, headr: true) }.message)
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
