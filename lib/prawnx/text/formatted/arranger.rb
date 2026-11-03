# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # Hands the line wrapper one string at a time out of formatted text, takes back what did not fit, and
      # measures the fragments of each finished line.
      class Arranger
        class NotFinalized < StandardError
          DEFAULT_MESSAGE = "Lines must be finalized"

          def initialize(message = DEFAULT_MESSAGE, method: nil)
            super((method && message == DEFAULT_MESSAGE) ? "Lines must be finalized before calling ##{method}" : message)
          end
        end

        class BadFontFamily < StandardError
          def initialize(message = "Bad font family")
            super
          end
        end

        # Relative size of subscript and superscript text.
        SCRIPT_SIZE_RATIO = 0.583

        attr_reader :max_line_height, :max_descender, :max_ascender, :finalized, :unconsumed, :fragments, :current_format_state
        attr_accessor :consumed

        def initialize(document, options = {})
          @document = document
          @fragments = []
          @unconsumed = []
          @kerning = options[:kerning]
        end

        def space_count
          raise NotFinalized.new(method: "space_count") unless finalized

          @fragments.sum(&:space_count)
        end

        def line_width
          raise NotFinalized.new(method: "line_width") unless finalized

          @fragments.inject(0) { |sum, fragment| sum + fragment.width }
        end

        def line
          raise NotFinalized.new(method: "line") unless finalized

          @fragments.map do |fragment|
            fragment.text.encode(::Encoding::UTF_8)
          rescue ::Encoding::InvalidByteSequenceError, ::Encoding::UndefinedConversionError
            fragment.text.dup.force_encoding(::Encoding::UTF_8)
          end.join
        end

        def finalize_line
          @finalized = true
          omit_trailing_whitespace_from_line_width
          @fragments = []
          @consumed.each do |hash|
            fragment = Fragment.new(hash[:text], hash.except(:text), @document)
            @fragments << fragment
            measure(fragment)
            @max_line_height = [@max_line_height, fragment.line_height].compact.max
            @max_descender = [@max_descender, fragment.descender].compact.max
            @max_ascender = [@max_ascender, fragment.ascender].compact.max
          end
        end

        def format_array=(array)
          initialize_line
          @unconsumed = []
          array.each do |hash|
            hash[:text].scan(/[^\n]+|\n/) { @unconsumed << hash.merge(text: _1) }
          end
        end

        def initialize_line
          @finalized = false
          @max_line_height = 0
          @max_descender = 0
          @max_ascender = 0
          @consumed = []
          @fragments = []
        end

        def finished?
          @unconsumed.empty?
        end

        def next_string
          raise NotFinalized.new(method: "next_string") if finalized

          next_unconsumed_hash = @unconsumed.shift
          return unless next_unconsumed_hash

          @consumed << next_unconsumed_hash.dup
          @current_format_state = next_unconsumed_hash.except(:text)
          next_unconsumed_hash[:text]
        end

        def preview_next_string
          @unconsumed.first&.fetch(:text)
        end

        def apply_color_and_font_settings(fragment, &)
          return apply_font_settings(fragment, &) unless fragment.color

          original_fill_color = @document.fill_color
          original_stroke_color = @document.stroke_color
          @document.fill_color(*fragment.color)
          @document.stroke_color(*fragment.color)
          apply_font_settings(fragment, &)
          @document.stroke_color = original_stroke_color
          @document.fill_color = original_fill_color
        end

        def apply_font_settings(fragment = nil, &)
          if fragment
            font = fragment.font
            size = fragment.size
            character_spacing = fragment.character_spacing
            styles = fragment.styles
          else
            font = current_format_state[:font]
            size = current_format_state[:size]
            character_spacing = current_format_state[:character_spacing] || @document.character_spacing
            styles = current_format_state[:styles]
          end
          font_style = font_style(styles)

          @document.character_spacing(character_spacing) do
            if font || font_style != :normal
              raise BadFontFamily unless @document.font.family

              @document.font(font || @document.font.family, style: font_style) { apply_font_size(size, styles, &) }
            else
              apply_font_size(size, styles, &)
            end
          end
        end

        def update_last_string(printed, unprinted, normalized_soft_hyphen = nil)
          return if printed.nil?

          if printed.empty?
            @consumed.pop
          else
            @consumed.last[:text] = printed
            @consumed.last[:normalized_soft_hyphen] = normalized_soft_hyphen if normalized_soft_hyphen
          end
          @unconsumed.unshift(@current_format_state.merge(text: unprinted)) unless unprinted.empty?
          load_previous_format_state if printed.empty?
        end

        def retrieve_fragment
          raise NotFinalized, "Lines must be finalized before fragments can be retrieved" unless finalized

          @fragments.shift
        end

        def repack_unretrieved
          new_unconsumed = []
          while (fragment = retrieve_fragment)
            fragment.include_trailing_white_space!
            new_unconsumed << fragment.format_state.merge(text: fragment.text)
          end
          @unconsumed = new_unconsumed.concat(@unconsumed)
        end

        def font_style(styles)
          styles = Array(styles)
          bold = styles.include?(:bold)
          italic = styles.include?(:italic)
          if bold && italic then :bold_italic
          elsif bold then :bold
          elsif italic then :italic
          else :normal
          end
        end

        private

        def load_previous_format_state
          @current_format_state = @consumed.empty? ? {} : @consumed.last.except(:text)
        end

        def apply_font_size(size, styles, &)
          if styles&.include?(:subscript) || styles&.include?(:superscript)
            size = (size || @document.font_size) * SCRIPT_SIZE_RATIO
          end
          size.nil? ? yield : @document.font_size(size, &)
        end

        def omit_trailing_whitespace_from_line_width
          @consumed.reverse_each do |hash|
            break if hash[:text] == "\n"

            hash[:exclude_trailing_white_space] = true
            break unless hash[:text].strip.empty? && @consumed.length > 1
          end
        end

        def measure(fragment)
          apply_font_settings(fragment) do
            fragment.width = @document.width_of(fragment.text, kerning: @kerning)
            fragment.line_height = @document.font.height
            fragment.descender = @document.font.descender
            fragment.ascender = @document.font.ascender
          end
        end
      end
    end
  end
end
