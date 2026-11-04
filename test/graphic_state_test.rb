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

  def test_a_blend_mode_block_keeps_its_blend_mode_on_the_next_page
    document = Prawn::Document.new do
      blend_mode(:Multiply) do
        text "Alice"
        start_new_page
        text "Bob"
      end
      text "Carol"
    end

    pdf = document.render

    assert_equal ["q", "/BMMultiply gs", "Bob", "Q", "q", "Carol", "Q"], operators(document.pages[1])
    assert_equal ["BMMultiply"], document.pages[1].resources[:ExtGState].keys
    assert_valid(pdf)
  end

  def test_nested_transparent_and_blend_mode_blocks_reopen_in_order
    document = Prawn::Document.new do
      blend_mode(:Screen) do
        transparent(0.5) do
          blend_mode(:Multiply) do
            text "Alice"
            start_new_page
            text "Bob"
          end
        end
      end
    end

    pdf = document.render

    assert_equal ["q", "/BMScreen gs", "q", "/Tr1 gs", "q", "/BMMultiply gs", "Bob", "Q", "Q", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_blend_mode_set_without_a_block_holds_on_the_next_page
    document = Prawn::Document.new do
      blend_mode(:Multiply)
      text "Alice"
      start_new_page
      text "Bob"
    end

    pdf = document.render

    assert_equal ["q", "/BMMultiply gs", "Bob", "Q"], operators(document.pages[1])
    assert_equal ["BMMultiply"], document.pages[1].resources[:ExtGState].keys
    assert_valid(pdf)
  end

  def test_a_blend_mode_set_without_a_block_inside_one_holds_until_the_block_ends
    document = Prawn::Document.new do
      save_graphics_state do
        blend_mode(:Multiply)
        start_new_page
        text "Bob"
      end
      text "Carol"
    end

    document.render

    assert_equal ["q", "/BMMultiply gs", "Bob", "Q", "q", "Carol", "Q"], operators(document.pages[1])
  end

  def test_a_blend_mode_set_inside_a_blend_mode_block_is_set_after_it_on_the_next_page
    document = Prawn::Document.new do
      blend_mode(:Screen) do
        blend_mode(:Multiply)
        start_new_page
        text "Bob"
      end
      text "Carol"
    end

    document.render

    assert_equal ["q", "/BMScreen gs", "/BMMultiply gs", "Bob", "Q", "q", "Carol", "Q"], operators(document.pages[1])
  end

  def test_a_blend_mode_set_before_a_block_crossing_a_page_break_follows_it
    document = Prawn::Document.new do
      blend_mode(:Multiply)
      transparent(0.5) do
        fill_color "0000cc"
        save_graphics_state do
          start_new_page
          text "Bob"
        end
        text "Carol"
      end
      text "Dave"
    end

    pdf = document.render

    # The new page sets the blend mode in the innermost block, and each block ending there sets it in the one around.
    assert_equal ["q", "/DeviceRGB cs", "0.0 0.0 0.8 scn", "/Tr1 gs", "q", "/BMMultiply gs", "Bob", "Q", "/BMMultiply gs", "Carol", "Q",
      "q", "/BMMultiply gs", "Dave", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_page_header_setting_its_own_blend_mode_keeps_it
    document = Prawn::Document.new do
      on_page_create { blend_mode(:Screen) }
      text "Alice"
      start_new_page
      text "Bob"
      blend_mode(:Multiply)
      start_new_page
      text "Carol"
    end

    document.render

    assert_equal ["q", "/BMScreen gs", "Bob", "/BMMultiply gs", "Q"], operators(document.pages[1])
    assert_equal ["q", "/BMScreen gs", "Carol", "Q"], operators(document.pages[2])
  end

  def test_a_soft_mask_sets_the_blend_mode_back_to_normal
    document = Prawn::Document.new do
      blend_mode(:Multiply)
      soft_mask { fill_rectangle [0, 100], 100, 100 }
      start_new_page
      text "Bob"
    end

    document.render

    assert_equal ["q", "Bob", "Q"], operators(document.pages[1])
  end

  def test_gradients_set_as_fill_and_stroke_hold_on_the_next_page
    document = Prawn::Document.new do
      fill_color "cc0000"
      fill_gradient [0, 0], [100, 0], "ff0000", "0000ff"
      stroke_gradient from: [0, 0], to: [0, 100], stops: %w[00ff00 000000]
      text "Alice"
      start_new_page
      text "Bob"
    end
    fill_gradient, stroke_gradient = document.pages[0].resources[:Pattern].keys
    fill_color = document.fill_color

    pdf = document.render

    assert_equal ["q", "/Pattern cs", "/#{fill_gradient} scn", "/Pattern CS", "/#{stroke_gradient} SCN", "Bob", "Q"], operators(document.pages[1])
    assert_equal [fill_gradient, stroke_gradient], document.pages[1].resources[:Pattern].keys
    assert_equal "cc0000", fill_color
    assert_valid(pdf)
  end

  def test_a_colour_set_after_a_gradient_replaces_it_on_the_next_page
    document = Prawn::Document.new do
      fill_gradient [0, 0], [100, 0], "ff0000", "0000ff"
      fill_color "cc0000"
      start_new_page
      text "Bob"
    end

    document.render

    assert_equal ["q", "/DeviceRGB cs", "0.8 0.0 0.0 scn", "Bob", "Q"], operators(document.pages[1])
    assert_nil document.pages[1].resources[:Pattern]
  end

  def test_a_gradient_set_before_a_block_crossing_a_page_break_follows_it
    document = Prawn::Document.new do
      fill_gradient [0, 0], [100, 0], "ff0000", "0000ff"
      save_graphics_state do
        fill_color "009900"
        start_new_page
        text "Bob"
      end
      text "Carol"
    end
    gradient = document.pages[0].resources[:Pattern].keys.first

    pdf = document.render

    assert_equal ["q", "/DeviceRGB cs", "0.0 0.6 0.0 scn", "Bob", "Q", "q", "/Pattern cs", "/#{gradient} scn", "Carol", "Q"],
      operators(document.pages[1])
    assert_valid(pdf)
  end

  def test_the_settings_before_a_block_crossing_a_page_break_follow_it
    document = Prawn::Document.new do
      fill_color "cc0000"
      stroke_color "0000cc"
      line_width 4
      dash 6
      cap_style :round
      join_style :bevel
      save_graphics_state do
        fill_color "009900"
        undash
        text "Alice"
        start_new_page
        text "Bob"
      end
      text "Carol"
    end
    settings = [document.fill_color, document.stroke_color, document.line_width, document.cap_style, document.join_style, document.dashed?]

    pdf = document.render

    assert_equal ["q", "/DeviceRGB cs", "0.0 0.6 0.0 scn", "/DeviceRGB CS", "0.0 0.0 0.8 SCN", "4 w", "1 J", "2 j", "Bob", "Q",
      "q", "/DeviceRGB cs", "0.8 0.0 0.0 scn", "/DeviceRGB CS", "0.0 0.0 0.8 SCN", "4 w", "1 J", "2 j", "[6.0 6.0] 0.0 d", "Carol", "Q"],
      operators(document.pages[1])
    assert_equal ["cc0000", "0000cc", 4, :round, :bevel, true], settings
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_each_block_crossing_a_page_break_ends_on_the_colour_set_before_it
    document = Prawn::Document.new do
      fill_color "cc0000"
      transparent(0.5) do
        fill_color "0000cc"
        save_graphics_state do
          fill_color "009900"
          start_new_page
          text "Bob"
        end
        text "Carol"
      end
      text "Dave"
    end

    pdf = document.render

    assert_equal ["q", "/DeviceRGB cs", "0.0 0.6 0.0 scn", "/Tr1 gs", "q", "Bob", "Q", "0.0 0.0 0.8 scn", "Carol", "Q",
      "q", "/DeviceRGB cs", "0.8 0.0 0.0 scn", "Dave", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_block_crossing_a_page_break_in_the_default_state_writes_nothing_back
    document = Prawn::Document.new do
      save_graphics_state do
        fill_color "009900"
        start_new_page
        text "Bob"
      end
      text "Carol"
    end
    fill_color = document.fill_color

    document.render

    assert_equal ["q", "/DeviceRGB cs", "0.0 0.6 0.0 scn", "Bob", "Q", "q", "Carol", "Q"], operators(document.pages[1])
    assert_equal "000000", fill_color
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

  # The page's graphics state, ExtGState and graphic settings operators, with its text in place of the operators
  # drawing it.
  def operators(page)
    page.content.stream.lines.map(&:chomp).filter_map do |line|
      next line if line.match?(/\A(?:q|Q|\/\w+ gs|.* (?:cs|CS|scn|SCN|w|J|j|d))\z/)

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
