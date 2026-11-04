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

  private

  def assert_balanced(page)
    depth = page.content.stream.lines.map(&:chomp).reduce(0) do |open, line|
      depth = open + {"q" => 1, "Q" => -1}.fetch(line, 0)
      assert_operator depth, :>=, 0, "Q without q:\n#{page.content.stream}"
      depth
    end
    assert_equal 0, depth, "q without Q:\n#{page.content.stream}"
  end
end
