# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Formatted text laid out in a rectangle: wrapped, aligned, shrunk or truncated to fit, possibly rotated.
      class Box
        include Wrap

        VALID_OPTIONS = (Text::VALID_OPTIONS + %i[
          at height width align valign rotate rotate_around overflow min_font_size disable_wrap_by_char leading
          character_spacing mode single_line document direction fallback_fonts draw_text_callback
        ]).freeze
        DEFAULT_MINIMUM_FONT_SIZE = 5
        SHRINK_STEP = 0.5

        attr_reader :text, :at, :line_height, :ascender, :descender, :leading

        # Modules every new box of this class extends itself with: a subclass starts with its parent's.
        def self.extensions
          @extensions ||= []
        end

        def self.inherited(subclass)
          super
          subclass.extensions.concat(extensions)
        end

        def initialize(formatted_text, options = {})
          @inked = false
          self.class.extensions.reverse_each { extend(_1) }
          Prawn.verify_options(valid_options, options)
          options = options.dup
          @overflow = options[:overflow] || :truncate
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @original_array = formatted_text
          @text = nil
          @document = options[:document]
          @direction = options[:direction] || @document.text_direction
          @fallback_fonts = options[:fallback_fonts] || @document.fallback_fonts
          @at = (options[:at] || [@document.bounds.left, @document.bounds.top]).dup
          @width = options[:width] || (@document.bounds.right - @at[0])
          @height = options[:height] || default_height
          @align = options[:align] || ((@direction == :rtl) ? :right : :left)
          @vertical_align = options[:valign] || :top
          @leading = options[:leading] || @document.default_leading
          @character_spacing = options[:character_spacing] || @document.character_spacing
          @mode = options[:mode] || @document.text_rendering_mode
          @mode = :fill if @mode == :unknown
          @rotate = options[:rotate] || 0
          @rotate_around = options[:rotate_around] || :upper_left
          @single_line = options[:single_line]
          @draw_text_callback = options[:draw_text_callback]
          if @overflow == :expand
            @height = default_height
            @overflow = :truncate
          end
          @min_font_size = options[:min_font_size] || DEFAULT_MINIMUM_FONT_SIZE
          options[:kerning] = @document.default_kerning? if options[:kerning].nil?
          @options = {kerning: options[:kerning], size: options[:size], style: options[:style]}
          super
        end

        def nothing_printed?
          @nothing_printed
        end

        def everything_printed?
          @everything_printed
        end

        def line_gap
          line_height - (ascender + descender)
        end

        def render(flags = {})
          unprinted_text = []
          @laid_out_lines = flags[:keep_layout] ? [] : nil
          with_text_settings do
            text = normalized_text(flags)
            shrink_to_fit(text) if @overflow == :shrink_to_fit
            process_vertical_alignment(text)
            @inked = true unless flags[:dry_run]
            unprinted_text = (@rotate != 0 && @inked) ? render_rotated(text) : wrap(text)
            @inked = false
          end
          unprinted_text.map { |fragment| fragment.merge(text: @document.font.to_utf8(fragment[:text])) }
        end

        # Whether the lines of a `render(dry_run: true, keep_layout: true)` can be drawn again as they are.
        def layout_reusable?
          !@laid_out_lines.nil? && @everything_printed && @rotate.zero? && @vertical_align == :top &&
            @overflow != :shrink_to_fit && self.class.extensions.empty? && @original_array.none? { _1[:color] }
        end

        # Draws, with its top left corner at `at`, the lines the last kept layout wrapped, without wrapping them again.
        def render_laid_out(at)
          @at = at.dup
          with_text_settings do
            @inked = true
            @laid_out_lines.each do |baseline_y, drawn_fragments|
              @baseline_y = baseline_y
              drawn_fragments.each { format_and_draw_fragment(*_1) }
            end
            @inked = false
          end
        end

        def available_width
          @width
        end

        def height
          return 0 if @baseline_y.nil? || @descender.nil?

          (@baseline_y - @descender).abs
        end

        def draw_fragment(fragment, accumulated_width = 0, line_width = 0, word_spacing = 0)
          x =
            case @align
            when :left then @at[0]
            when :center then @at[0] + (@width * 0.5) - (line_width * 0.5)
            when :right then @at[0] + @width - line_width
            when :justify then (@direction == :ltr) ? @at[0] : @at[0] + @width - line_width
            else raise ArgumentError, "align must be one of :left, :right, :center or :justify symbols"
            end
          x += accumulated_width
          y = @at[1] + @baseline_y + fragment.y_offset
          fragment.left = x
          fragment.baseline = y
          return unless @inked

          fragment.callback_objects.each { |callback| callback.render_behind(fragment) if callback.respond_to?(:render_behind) }
          @document.word_spacing(word_spacing) do
            if @draw_text_callback
              @draw_text_callback.call(fragment.text, at: [x, y], kerning: @kerning)
            else
              @document.draw_text!(fragment.text, at: [x, y], kerning: @kerning)
            end
          end
          draw_fragment_overlays(fragment)
        end

        def valid_options
          VALID_OPTIONS
        end

        private

        def with_text_settings(&)
          @document.save_font do
            @document.character_spacing(@character_spacing) do
              @document.text_rendering_mode(@mode) do
                process_options
                @document.font_size(@font_size, &)
              end
            end
          end
        end

        def normalized_text(flags)
          text = normalize_encoding
          text.each { _1.delete(:color) } if flags[:dry_run]
          text
        end

        def original_text
          @original_array.map(&:dup)
        end

        def normalize_encoding
          formatted_text = original_text
          formatted_text = formatted_text.flat_map { fragments_by_fallback_font(_1) } unless @fallback_fonts.empty?
          formatted_text.each do |hash|
            if hash[:font]
              @document.font(hash[:font]) { hash[:text] = @document.font.normalize_encoding(hash[:text]) }
            else
              hash[:text] = @document.font.normalize_encoding(hash[:text])
            end
          end
          formatted_text
        end

        def fragments_by_fallback_font(hash)
          original_font = @document.font.family
          fragment_font = hash[:font] || original_font
          fragment_font_style = @arranger.font_style(hash[:styles])
          fragment_font_options = (fragment_font_style == :normal) ? {} : {style: fragment_font_style}
          fallback_fonts = [*@fallback_fonts, fragment_font]

          font_glyph_pairs = []
          @document.save_font do
            hash[:text].each_char do |character|
              font_glyph_pairs << [font_for_glyph(character, fragment_font, fallback_fonts.dup, fragment_font_options), character]
            end
          end
          font_glyph_pairs.each { |pair| pair[0] = nil if pair[0] == original_font } if hash[:font].nil?

          fragments = []
          current_font = nil
          font_glyph_pairs.each do |font, character|
            if font != current_font || fragments.empty?
              current_font = font
              fragment = hash.merge(text: character)
              fragment[:font] = font unless font.nil?
              fragments << fragment
            else
              fragments.last[:text] += character
            end
          end
          fragments
        end

        def font_for_glyph(character, current_font, fallback_fonts, current_font_options = {})
          loop do
            @document.font(current_font, current_font_options)
            return current_font if fallback_fonts.empty? || @document.font.glyph_present?(character)

            current_font = fallback_fonts.shift
          end
        end

        def move_baseline_down
          if @baseline_y.zero?
            @baseline_y = -@ascender
          else
            @baseline_y -= @line_height + @leading
          end
        end

        def default_height
          frame = @document.bounds
          frame = frame.parent while frame.stretchy? && frame.parent
          @at[1] + @document.bounds.absolute_bottom - frame.absolute_bottom
        end

        def process_vertical_alignment(text)
          return if @vertical_alignment_processed

          @vertical_alignment_processed = true
          return if @vertical_align == :top

          wrap(text)
          case @vertical_align
          when :center then @at[1] -= (@height - height + @descender) * 0.5
          when :bottom then @at[1] -= @height - height
          else raise ArgumentError, "valign must be one of :left, :right or :center symbols"
          end
          @height = height
        end

        def shrink_to_fit(text)
          loop do
            if @disable_wrap_by_char && @font_size > @min_font_size
              begin
                wrap(text)
              rescue Errors::CannotFit
                # Too big for a word to fit whole: the next, smaller size may make it fit.
              end
            else
              wrap(text)
            end
            break if @everything_printed || @font_size <= @min_font_size

            @font_size = [@font_size - SHRINK_STEP, @min_font_size].max
            @document.font_size = @font_size
          end
        end

        def process_options
          @document.process_text_options(@options)
          @font_size = @options[:size]
          @kerning = @options[:kerning]
        end

        def render_rotated(text)
          x, y =
            case @rotate_around
            when :center then [@at[0] + (@width * 0.5), @at[1] - (@height * 0.5)]
            when :upper_right then [@at[0] + @width, @at[1]]
            when :lower_right then [@at[0] + @width, @at[1] - @height]
            when :lower_left then [@at[0], @at[1] - @height]
            else [@at[0], @at[1]]
            end
          unprinted_text = ""
          @document.rotate(@rotate, origin: [x, y]) { unprinted_text = wrap(text) }
          unprinted_text
        end

        def draw_fragment_overlays(fragment)
          @document.stroke_line(fragment.underline_points) if fragment.styles.include?(:underline)
          @document.stroke_line(fragment.strikethrough_points) if fragment.styles.include?(:strikethrough)
          draw_link_annotations(fragment)
          fragment.callback_objects.each { |callback| callback.render_in_front(fragment) if callback.respond_to?(:render_in_front) }
        end

        def draw_link_annotations(fragment)
          if fragment.link
            @document.link_annotation(fragment.absolute_bounding_box, Border: [0, 0, 0],
              A: {Type: :Action, S: :URI, URI: PDF::Core::LiteralString.new(fragment.link)})
          end
          @document.link_annotation(fragment.absolute_bounding_box, Border: [0, 0, 0], Dest: fragment.anchor) if fragment.anchor
          return unless fragment.local

          @document.link_annotation(fragment.absolute_bounding_box, Border: [0, 0, 0],
            A: {Type: :Action, S: :Launch, F: PDF::Core::LiteralString.new(fragment.local), NewWindow: true})
        end
      end
    end
  end
end
