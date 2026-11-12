# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Lays formatted text out line by line inside a box's width and height.
      module Wrap
        def initialize(_array, options)
          @line_wrap = LineWrap.new
          @arranger = Arranger.new(@document, kerning: options[:kerning])
          @disable_wrap_by_char = options[:disable_wrap_by_char]
        end

        def wrap(array)
          initialize_wrap(array)
          loop do
            @line_wrap.wrap_line(document: @document, kerning: @kerning, width: available_width, arranger: @arranger,
              disable_wrap_by_char: @disable_wrap_by_char)
            break unless enough_height_for_this_line?

            move_baseline_down
            print_line
            break if @single_line || @arranger.finished?
          end
          @text = @printed_lines.join("\n")
          @everything_printed = @arranger.finished?
          @arranger.unconsumed
        end

        private

        def print_line
          @nothing_printed = false
          printed_fragments = []
          fragments_this_line = []
          word_spacing = word_spacing_for_this_line
          @arranger.fragments.each do |fragment|
            fragment.word_spacing = word_spacing
            if fragment.text == "\n"
              printed_fragments << "\n" if @printed_lines.last == ""
              break
            end
            printed_fragments << fragment.text
            fragments_this_line << fragment
          end
          @arranger.fragments.replace([])

          accumulated_width = 0
          drawn_fragments = []
          fragments_this_line.reverse! if @direction == :rtl
          fragments_this_line.each do |fragment|
            fragment.default_direction = @direction
            drawn_fragment = [fragment, accumulated_width, @line_wrap.width, word_spacing]
            format_and_draw_fragment(*drawn_fragment)
            drawn_fragments << drawn_fragment if @laid_out_lines
            accumulated_width += fragment.width
          end
          @laid_out_lines << [@baseline_y, drawn_fragments, @descender] if @laid_out_lines
          @printed_lines << printed_fragments.map { _1.dup.force_encoding(::Encoding::UTF_8) }.join
        end

        def word_spacing_for_this_line
          return 0 unless @align == :justify && @line_wrap.space_count.positive? && !@line_wrap.paragraph_finished?

          (available_width - @line_wrap.width) / @line_wrap.space_count
        end

        # Slack in points, so floating point sums do not drop a line that fits exactly.
        HEIGHT_TOLERANCE = 0.0001

        def enough_height_for_this_line?
          @line_height = @arranger.max_line_height
          @descender = @arranger.max_descender
          @ascender = @arranger.max_ascender
          line_extent = @baseline_y.zero? ? @ascender + @descender : @descender + @line_height + @leading
          return true if @baseline_y.abs + line_extent <= @height + HEIGHT_TOLERANCE

          @arranger.repack_unretrieved
          false
        end

        def initialize_wrap(array)
          @text = nil
          @arranger.format_array = array
          @line_height = 0
          @descender = 0
          @ascender = 0
          @baseline_y = 0
          @printed_lines = []
          @laid_out_lines&.clear
          @nothing_printed = true
          @everything_printed = false
        end

        def format_and_draw_fragment(fragment, accumulated_width, line_width, word_spacing)
          @arranger.apply_color_and_font_settings(fragment) do
            draw_fragment(fragment, accumulated_width, line_width, word_spacing)
          end
        end
      end
    end
  end
end
