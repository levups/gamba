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

  def test_text_state_blocks_hold_on_the_next_page_and_end_as_they_began
    document = Prawn::Document.new do
      text_rendering_mode(:stroke) do
        character_spacing(3) do
          word_spacing(2) do
            horizontal_text_scaling(70) do
              rise(4) do
                text "Alice"
                start_new_page
                text "Bob"
              end
            end
          end
        end
      end
      text "Carol"
    end

    pdf = document.render

    # The fragment's own word spacing, 0 unless justified, surrounds Bob as on any page.
    assert_equal ["q", "1 Tr", "3.0 Tc", "2.0 Tw", "70.0 Tz", "4.0 Ts", "0.0 Tw", "Bob", "2.0 Tw",
      "0.0 Ts", "100.0 Tz", "0.0 Tw", "0.0 Tc", "0 Tr", "Carol", "Q"], operators(document.pages[1])
    assert_valid(pdf)
  end

  def test_a_block_ending_on_a_later_page_writes_back_the_text_state_of_the_blocks_around_it
    document = Prawn::Document.new do
      character_spacing(3) do
        transparent(0.5) do
          start_new_page
          text "Bob"
        end
        text "Carol"
      end
      text "Dave"
    end

    pdf = document.render

    assert_equal ["q", "3.0 Tc", "/Tr1 gs", "Bob", "Q", "q", "3.0 Tc", "Carol", "0.0 Tc", "Dave", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_save_ending_on_a_later_page_inside_a_text_state_block_writes_it_back
    document = Prawn::Document.new do
      character_spacing(3) do
        save_graphics_state do
          character_spacing(1) { text "Alice" }
          start_new_page
          text "Bob"
        end
        text "Carol"
      end
    end

    document.render

    assert_equal ["q", "3.0 Tc", "Bob", "Q", "q", "3.0 Tc", "Carol", "0.0 Tc", "Q"], operators(document.pages[1])
  end

  def test_text_flowing_onto_an_existing_page_keeps_the_text_state_of_its_block
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      character_spacing(2) do
        go_to_page(2)
        text "Bob"
      end
    end

    document.render

    assert_equal ["q", "2.0 Tc", "Bob", "0.0 Tc", "Q"], operators(document.pages[1])
  end

  def test_page_numbers_drawn_after_a_block_ended_on_a_later_page_do_not_take_its_text_state
    document = Prawn::Document.new do
      text_rendering_mode(:invisible) do
        text "Alice"
        start_new_page
        text "Bob"
      end
      number_pages "<page>", at: [0, 0]
    end

    pdf = document.render

    assert_equal ["q", "3 Tr", "Alice", "0 Tr", "1", "Q"], operators(document.pages[0])
    assert_equal ["q", "3 Tr", "Bob", "0 Tr", "2", "Q"], operators(document.pages[1])
    assert_valid(pdf)
  end

  def test_a_state_given_to_a_save_inherits_the_text_state_of_the_page
    document = Prawn::Document.new
    given = nil
    document.character_spacing(2) { given = document.graphic_state.dup }
    recorded = nil

    document.save_graphics_state(given) { recorded = document.graphic_state.character_spacing }

    assert_equal [2, 0], [given.character_spacing, recorded]
  end

  def test_page_numbers_are_drawn_outside_a_block_that_ended_on_another_page
    document = Prawn::Document.new do
      transparent(0.5) do
        text "Alice"
        start_new_page
        text "Bob"
      end
      number_pages "<page>", at: [0, 0]
    end

    pdf = document.render

    assert_equal ["q", "q", "/Tr1 gs", "Alice", "Q", "1", "Q"], operators(document.pages[0])
    assert_equal ["q", "/Tr1 gs", "Bob", "Q", "q", "2", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_content_drawn_again_on_a_page_a_transparent_block_ran_through_takes_the_settings_before_it
    document = Prawn::Document.new do
      fill_color "0000ff"
      transparent(0.5) do
        fill_color "ff0000"
        start_new_page
        start_new_page
      end
      go_to_page(2)
      text "Bob"
    end
    fill_color = document.fill_color

    pdf = document.render

    assert_equal "0000ff", fill_color
    assert_equal ["q", "/DeviceRGB cs", "1.0 0.0 0.0 scn", "/Tr1 gs", "Q", "q", "/DeviceRGB cs", "0.0 0.0 1.0 scn", "Bob", "Q"],
      operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_content_drawn_again_on_a_page_a_block_ran_through_takes_the_settings_before_it
    document = Prawn::Document.new do
      fill_color "0000ff"
      save_graphics_state do
        fill_color "ff0000"
        start_new_page
        start_new_page
      end
      go_to_page(2)
      text "Bob"
    end
    fill_color = document.fill_color

    document.render

    assert_equal "0000ff", fill_color
    assert_equal ["q", "/DeviceRGB cs", "1.0 0.0 0.0 scn", "Q", "q", "/DeviceRGB cs", "0.0 0.0 1.0 scn", "Bob", "Q"],
      operators(document.pages[1])
  end

  def test_content_drawn_again_on_a_page_stays_inside_the_blocks_still_open
    document = Prawn::Document.new do
      transparent(0.5) do
        float do
          text "Alice"
          start_new_page
          text "Bob"
        end
        text "Carol"
      end
    end

    document.render

    assert_equal ["q", "q", "/Tr1 gs", "Alice", "Carol", "Q", "Q"], operators(document.pages[0])
  end

  def test_a_forgotten_text_rendering_mode_is_not_written_on_the_next_page
    document = Prawn::Document.new do
      forget_text_rendering_mode!
      start_new_page
      draw_text "Bob", at: [0, 0]
    end

    document.render

    assert_equal ["q", "Bob", "Q"], operators(document.pages[1])
  end

  def test_a_text_rendering_mode_block_after_the_mode_was_forgotten_restores_nothing
    document = Prawn::Document.new do
      forget_text_rendering_mode!
      text_rendering_mode(:stroke) { draw_text "Alice", at: [0, 0] }
    end

    pdf = document.render

    assert_equal :unknown, document.text_rendering_mode
    assert_equal ["q", "1 Tr", "Alice", "Q"], operators(document.pages[0])
    assert_valid pdf
  end

  def test_text_drawn_after_the_mode_was_forgotten_is_filled_without_restoring_it
    document = Prawn::Document.new do
      forget_text_rendering_mode!
      text "Alice"
      text "Bob"
    end

    pdf = document.render

    assert_equal :unknown, document.text_rendering_mode
    assert_equal ["q", "0 Tr", "Alice", "0 Tr", "Bob", "Q"], operators(document.pages[0])
    assert_valid pdf
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

  def test_text_flowing_onto_an_existing_page_keeps_the_opacity_of_its_block
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      move_down 650
      transparent(0.3) { text "Faded line. " * 120 }
    end

    pdf = document.render

    lines = operators(document.pages[1])
    assert_equal ["q", "q", "/Tr1 gs"], lines.first(3)
    assert_equal ["Q", "Q"], lines.last(2)
    assert_equal ["Tr1"], document.pages[1].resources[:ExtGState].keys
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_transparent_block_ending_on_an_existing_page_covers_only_what_it_adds_there
    document = Prawn::Document.new do
      start_new_page
      text "Bob"
      go_to_page(1)
      transparent(0.5) do
        text "Alice"
        go_to_page(2)
        text "Carol"
      end
      text "Dave"
    end

    pdf = document.render

    assert_equal ["q", "Bob", "q", "/Tr1 gs", "Carol", "Q", "Dave", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_block_back_on_an_existing_page_it_reopened_reopens_it_once
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      transparent(0.5) do
        go_to_page(2)
        text "Bob"
        go_to_page(1)
        text "Alice"
        go_to_page(2)
        text "Carol"
      end
    end

    document.render

    assert_equal ["q", "q", "/Tr1 gs", "Alice", "Q", "Q"], operators(document.pages[0])
    assert_equal ["q", "q", "/Tr1 gs", "Bob", "Carol", "Q", "Q"], operators(document.pages[1])
  end

  def test_nested_blocks_reopen_in_order_on_an_existing_page
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      save_graphics_state do
        transparent(0.5) do
          blend_mode(:Multiply) do
            go_to_page(2)
            text "Bob"
          end
          text "Carol"
        end
        text "Dave"
      end
      text "Eve"
    end

    pdf = document.render

    assert_equal ["q", "q", "q", "/Tr1 gs", "q", "/BMMultiply gs", "Bob", "Q", "Carol", "Q", "Dave", "Q", "Eve", "Q"],
      operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_block_crossing_an_existing_page_then_a_new_one_keeps_its_opacity_on_both
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      transparent(0.5) do
        text "Alice"
        go_to_page(2)
        text "Bob"
        start_new_page
        text "Carol"
      end
      text "Dave"
      number_pages "<page>", at: [0, 0]
    end

    pdf = document.render

    assert_equal ["q", "q", "/Tr1 gs", "Bob", "Q", "2", "Q"], operators(document.pages[1])
    assert_equal ["q", "/Tr1 gs", "Carol", "Q", "q", "Dave", "3", "Q"], operators(document.pages[2])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_page_numbers_on_an_existing_page_a_block_flowed_onto_are_drawn_outside_it
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      transparent(0.5) do
        text "Alice"
        go_to_page(2)
        text "Bob"
      end
      go_to_page(1)
      text "Carol"
      number_pages "<page>", at: [0, 0]
    end

    pdf = document.render

    assert_equal ["q", "q", "/Tr1 gs", "Alice", "Q", "Carol", "1", "Q"], operators(document.pages[0])
    assert_equal ["q", "q", "/Tr1 gs", "Bob", "Q", "2", "Q"], operators(document.pages[1])
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_a_block_without_an_ext_gstate_reopens_nothing_on_an_existing_page
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      save_graphics_state do
        go_to_page(2)
        text "Bob"
      end
    end

    document.render

    assert_equal ["q", "Bob", "Q"], operators(document.pages[1])
  end

  def test_text_flowing_onto_an_existing_page_keeps_the_settings_in_effect_as_on_a_new_page
    settings = proc do
      fill_color "cc0000"
      stroke_color "0000cc"
      line_width 4
      dash 6
      cap_style :round
      join_style :bevel
      text "Alice line. " * 60
    end
    existing_page = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      move_down 650
      instance_eval(&settings)
    end
    new_page = Prawn::Document.new do
      move_down 650
      instance_eval(&settings)
    end

    pdf = existing_page.render
    new_page.render

    assert_equal ["q", "/DeviceRGB cs", "0.8 0.0 0.0 scn", "/DeviceRGB CS", "0.0 0.0 0.8 SCN", "4 w", "1 J", "2 j", "[6.0 6.0] 0.0 d"],
      operators(existing_page.pages[1]).first(9)
    assert_equal operators(new_page.pages[1]), operators(existing_page.pages[1])
    existing_page.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_text_flowing_onto_an_existing_page_draws_with_the_settings_in_effect_not_the_pages_own
    document = Prawn::Document.new do
      start_new_page
      fill_color "0000cc"
      line_width 3
      text "Bob"
      go_to_page(1)
      move_down 650
      text "Alice line. " * 60
    end

    document.render

    lines = operators(document.pages[1])
    assert_equal ["q", "/DeviceRGB cs", "0.0 0.0 0.8 scn", "3 w", "Bob", "0.0 0.0 0.0 scn", "1 w"], lines.first(7)
    assert_equal ["Alice line. Alice line. Alice line.", "Q"], lines.last(2)
  end

  def test_a_blend_mode_set_without_a_block_holds_on_an_existing_page_text_flows_onto
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      move_down 650
      blend_mode(:Multiply)
      text "Alice line. " * 60
    end

    pdf = document.render

    assert_equal ["q", "/BMMultiply gs"], operators(document.pages[1]).first(2)
    assert_equal ["BMMultiply"], document.pages[1].resources[:ExtGState].keys
    assert_valid(pdf)
  end

  def test_a_gradient_holds_on_an_existing_page_text_flows_onto
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      move_down 650
      fill_gradient [0, 0], [100, 0], "ff0000", "0000ff"
      text "Alice line. " * 60
    end
    gradient = document.pages[0].resources[:Pattern].keys.first

    pdf = document.render

    assert_equal ["q", "/Pattern cs", "/#{gradient} scn"], operators(document.pages[1]).first(3)
    assert_equal [gradient], document.pages[1].resources[:Pattern].keys
    assert_valid(pdf)
  end

  def test_a_block_flowing_onto_an_existing_page_draws_in_its_colour_then_ends_on_the_one_before_it
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      move_down 650
      fill_color "cc0000"
      transparent(0.5) do
        fill_color "0000cc"
        text "Alice line. " * 60
      end
      text "Dave"
    end

    pdf = document.render

    lines = operators(document.pages[1])
    assert_equal ["q", "q", "/Tr1 gs", "/DeviceRGB cs", "0.0 0.0 0.8 scn"], lines.first(5)
    assert_equal ["Q", "/DeviceRGB cs", "0.8 0.0 0.0 scn", "Dave", "Q"], lines.last(5)
    document.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  def test_go_to_page_alone_keeps_the_pages_own_settings
    document = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      fill_color "cc0000"
      line_width 4
      go_to_page(2)
      text "Bob"
    end

    document.render

    assert_equal ["q", "Bob", "Q"], operators(document.pages[1])
  end

  def test_page_numbers_and_repeaters_after_text_flowed_onto_an_existing_page_draw_as_on_a_new_page
    body = proc do
      fill_color "cc0000"
      text "Alice line. " * 60
      fill_color "0000cc"
      go_to_page(1)
      number_pages "<page>", at: [0, 0]
      repeat(:all, dynamic: true) { draw_text "Carol", at: [0, 20] }
    end
    existing_page = Prawn::Document.new do
      start_new_page
      go_to_page(1)
      move_down 650
      instance_eval(&body)
    end
    new_page = Prawn::Document.new do
      move_down 650
      instance_eval(&body)
    end

    pdf = existing_page.render
    new_page.render

    lines = operators(existing_page.pages[1])
    assert_equal ["q", "/DeviceRGB cs", "0.8 0.0 0.0 scn"], lines.first(3)
    assert_equal ["Alice line. Alice line. Alice line.", "0.0 0.0 0.8 scn", "2", "q"], lines.drop_while { _1 != "Alice line. Alice line. Alice line." }.first(4)
    assert_equal operators(new_page.pages[1]), operators(existing_page.pages[1])
    existing_page.pages.each { assert_balanced(_1) }
    assert_valid(pdf)
  end

  private

  # The page's graphics state, ExtGState, graphic settings and text state operators, with its text in place of the operators
  # drawing it.
  def operators(page)
    page.content.stream.lines.map(&:chomp).filter_map do |line|
      next line if line.match?(/\A(?:q|Q|\/\w+ gs|.* (?:cs|CS|scn|SCN|w|J|j|d|Tr|Tc|Tw|Tz|Ts))\z/)

      [line.scan(/<(\h+)>/).join].pack("H*") if line.end_with?(" TJ")
    end
  end

  def assert_valid(pdf)
    skip "qpdf or pdftotext is not installed" unless system("qpdf", "--version", out: File::NULL) && system("pdftotext", "-v", err: File::NULL)
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
