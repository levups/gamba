# frozen_string_literal: true

require_relative "test_helper"
require "prawn"

# Blocks saving the graphics state may cross a page break: each page must still open and close as many states as it
# saves, and a restore matching no save must still raise.
class GraphicStateTest < Minitest::Test
  def test_nested_blocks_restored_after_a_page_break_close_every_page
    document = Prawn::Document.new do
      transparent(0.9) do
        transparent(0.6) do
          text "Alice"
          start_new_page
        end
      end
      text "Bob"
    end

    document.render

    assert_equal 2, document.page_count
    document.pages.each { assert_balanced(_1) }
  end

  def test_a_restore_matching_no_save_raises
    document = Prawn::Document.new
    document.restore_graphics_state

    assert_raises(PDF::Core::Errors::EmptyGraphicStateStack) { document.restore_graphics_state }
  end

  def test_a_restore_beyond_the_blocks_open_at_a_page_break_raises
    document = Prawn::Document.new
    2.times { document.save_graphics_state }
    document.start_new_page
    2.times { document.restore_graphics_state }

    assert_raises(PDF::Core::Errors::EmptyGraphicStateStack) { document.restore_graphics_state }
  end

  def test_a_transparent_block_keeps_its_opacity_on_the_next_page
    document = Prawn::Document.new do
      transparent(0.5) do
        text "Alice"
        start_new_page
        text "Bob"
      end
      text "Carol"
    end

    pdf = document.render

    assert_equal ["q", "/Tr1 gs", "Bob", "Q", "q", "Carol", "Q"], operators(document.pages[1])
    assert_equal ["Tr1"], document.pages[1].resources[:ExtGState].keys
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_nested_blocks_keep_their_opacities_in_order_on_the_next_page
    document = Prawn::Document.new do
      transparent(0.8) do
        save_graphics_state do
          transparent(0.5, 0.25) do
            text "Alice"
            start_new_page
            text "Bob"
          end
          text "Carol"
        end
        text "Dave"
      end
      text "Eve"
    end

    pdf = document.render

    assert_equal ["q", "/Tr1 gs", "q", "q", "/Tr2 gs", "Bob", "Q", "Carol", "Q", "Dave", "Q", "q", "Eve", "Q"], operators(document.pages[1])
    assert_equal %w[Tr1 Tr2], document.pages[1].resources[:ExtGState].keys
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_the_next_page_draws_its_header_before_reopening_the_blocks
    document = Prawn::Document.new do
      on_page_create { text "Header" }
      transparent(0.5) do
        start_new_page
        text "Bob"
      end
    end

    document.render

    assert_equal ["q", "Header", "/Tr1 gs", "Bob", "Q"], operators(document.pages[1])
  end

  def test_a_page_break_without_a_transparent_block_open_reopens_nothing
    document = Prawn::Document.new do
      save_graphics_state do
        text "Alice"
        start_new_page
        text "Bob"
      end
    end

    document.render

    assert_equal ["q", "Bob", "Q"], operators(document.pages[1])
  end

  private

  # The page's graphics state and ExtGState operators, with its text in place of the operators drawing it.
  def operators(page)
    page.content.stream.lines.map(&:chomp).filter_map do |line|
      next line if line.match?(/\A(?:q|Q|\/Tr\d+ gs)\z/)

      [line.scan(/<(\h+)>/).join].pack("H*") if line.end_with?(" TJ")
    end
  end

  def assert_valid(pdf)
    skip "qpdf is not installed" unless system("qpdf", "--version", out: File::NULL)
    Tempfile.create(["graphic_state", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      assert_nil Oracle.invalidity(file.path)
    end
  end

  def assert_balanced(page)
    depth = page.content.stream.lines.map(&:chomp).reduce(0) do |open, line|
      depth = open + {"q" => 1, "Q" => -1}.fetch(line, 0)
      assert_operator depth, :>=, 0, "Q without q:\n#{page.content.stream}"
      depth
    end
    assert_equal 0, depth, "q without Q:\n#{page.content.stream}"
  end
end
