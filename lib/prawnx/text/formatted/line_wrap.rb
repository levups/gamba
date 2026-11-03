# frozen_string_literal: true

require "strscan"

module Prawn
  module Text
    module Formatted
      # Fills one line with as many words of the arranger's fragments as fit, breaking after spaces, hyphens and
      # soft hyphens, and inside a word only when the line holds a single one.
      class LineWrap
        # Characters and patterns of one encoding, computed once: Prawn rebuilt them for every line.
        Breaks = Data.define(:soft_hyphen, :zero_width_space, :scan_pattern, :word_division_pattern, :ends_with_break_pattern,
          :last_word_pattern, :begins_with_break_pattern)

        BREAKS_BY_ENCODING = Hash.new do |cache, encoding|
          cache[encoding] = breaks_for(encoding)
        end

        def self.encode_or_nil(character, encoding)
          character.encode(encoding)
        rescue ::Encoding::InvalidByteSequenceError, ::Encoding::UndefinedConversionError
          nil
        end

        def self.breaks_for(encoding)
          soft_hyphen = encode_or_nil(SHY, encoding)
          zero_width_space = encode_or_nil(ZWSP, encoding)
          whitespace = " \t#{zero_width_space}".encode(encoding)
          break_characters = [whitespace, soft_hyphen, "-"].join
          patterns = ["[^#{break_characters}]+#{soft_hyphen}", "[^#{break_characters}]+-+", "[^#{break_characters}]+", "[#{whitespace}]+",
            "-+[^#{break_characters}]*", soft_hyphen.to_s]
          Breaks.new(
            soft_hyphen: soft_hyphen&.freeze,
            zero_width_space: zero_width_space&.freeze,
            scan_pattern: Regexp.new(patterns.map { it.encode(encoding) }.join("|")),
            word_division_pattern: Regexp.union([*["\t", "\n", "\v", "\r", " "].map { it.encode(encoding) }, zero_width_space, soft_hyphen, "-"].compact),
            ends_with_break_pattern: Regexp.new("[#{break_characters}]$"),
            last_word_pattern: Regexp.new("[^#{break_characters}]*$"),
            begins_with_break_pattern: Regexp.new("^[#{break_characters}]")
          )
        end

        attr_reader :space_count

        def width
          @accumulated_width || 0
        end

        def paragraph_finished?
          @newline_encountered || next_string_newline? || @arranger.finished?
        end

        def tokenize(fragment)
          fragment.scan(BREAKS_BY_ENCODING[fragment.encoding].scan_pattern)
        end

        def wrap_line(options)
          initialize_line(options)
          while (fragment = @arranger.next_string)
            @fragment_output = +""
            fragment.lstrip! if first_fragment_on_this_line?(fragment)
            next if empty_line?(fragment)
            break unless apply_font_settings_and_add_fragment_to_line(fragment)
          end
          @arranger.finalize_line
          @accumulated_width = @arranger.line_width
          @space_count = @arranger.space_count
          @arranger.line
        end

        private

        def first_fragment_on_this_line?(fragment)
          line_empty? && fragment != "\n"
        end

        def empty_line?(fragment)
          empty = line_empty? && fragment.empty? && next_string_newline?
          @arranger.update_last_string("", "", BREAKS_BY_ENCODING[fragment.encoding].soft_hyphen) if empty
          empty
        end

        def next_string_newline?
          @arranger.preview_next_string == "\n"
        end

        def apply_font_settings_and_add_fragment_to_line(fragment)
          added = nil
          @arranger.apply_font_settings { added = add_fragment_to_line(fragment) }
          added
        end

        def add_fragment_to_line(fragment)
          case fragment
          when "" then return true
          when "\n"
            @newline_encountered = true
            return false
          end

          breaks = BREAKS_BY_ENCODING[fragment.encoding]
          # Words are read one at a time: a line stops long before the end of its paragraph.
          scanner = StringScanner.new(fragment)
          while (segment = scanner.scan(breaks.scan_pattern))
            segment_width = (segment == breaks.zero_width_space) ? 0 : @document.width_of(segment, kerning: @kerning)
            if @accumulated_width + segment_width <= @width
              @accumulated_width += segment_width
              @accumulated_width -= @document.width_of(breaks.soft_hyphen, kerning: @kerning) if segment[-1] == breaks.soft_hyphen
              @fragment_output << segment
            else
              @line_contains_more_than_one_word = false if @accumulated_width.zero? && @line_contains_more_than_one_word
              end_of_the_line_reached(segment)
              fragment_finished(fragment)
              return false
            end
          end
          fragment_finished(fragment)
          true
        end

        def line_empty?
          @line_empty && @accumulated_width.zero?
        end

        def initialize_line(options)
          @document = options[:document]
          @kerning = options[:kerning]
          @width = options[:width]
          @disable_wrap_by_char = options[:disable_wrap_by_char]
          @accumulated_width = 0
          @line_empty = true
          @line_contains_more_than_one_word = false
          @arranger = options[:arranger]
          @arranger.initialize_line
          @newline_encountered = false
          @line_full = false
        end

        def fragment_finished(fragment)
          if fragment == "\n"
            @newline_encountered = true
            @line_empty = false
          else
            update_output_based_on_last_fragment(fragment, BREAKS_BY_ENCODING[fragment.encoding].soft_hyphen)
            update_line_status_based_on_last_output
            pull_preceding_fragment_to_join_this_one?(fragment)
          end
          remember_this_fragment_for_backward_looking_ops
        end

        def update_output_based_on_last_fragment(fragment, normalized_soft_hyphen = nil)
          remaining_text = fragment.slice(@fragment_output.length..fragment.length)
          raise Errors::CannotFit if line_finished? && line_empty? && @fragment_output.empty? && !fragment.strip.empty?

          @arranger.update_last_string(@fragment_output, remaining_text, normalized_soft_hyphen)
        end

        def pull_preceding_fragment_to_join_this_one?(current_fragment)
          return unless @fragment_output.empty? && !current_fragment.empty? && @line_contains_more_than_one_word
          return if @previous_fragment_ended_with_breakable || fragment_begins_with_breakable?(current_fragment)

          @fragment_output = @previous_fragment_output_without_last_word
          update_output_based_on_last_fragment(@previous_fragment)
        end

        def remember_this_fragment_for_backward_looking_ops
          @previous_fragment = @fragment_output.dup
          breaks = BREAKS_BY_ENCODING[@previous_fragment.encoding]
          @previous_fragment_ended_with_breakable = @previous_fragment.match?(breaks.ends_with_break_pattern)
          last_word = @previous_fragment.slice(breaks.last_word_pattern)
          @previous_fragment_output_without_last_word = @previous_fragment.slice(0, @previous_fragment.length - (last_word&.length || 0))
        end

        def fragment_begins_with_breakable?(fragment)
          fragment.match?(BREAKS_BY_ENCODING[fragment.encoding].begins_with_break_pattern)
        end

        def line_finished?
          @line_full || paragraph_finished?
        end

        def update_line_status_based_on_last_output
          @line_contains_more_than_one_word = true if @fragment_output&.match?(BREAKS_BY_ENCODING[@fragment_output.encoding].word_division_pattern)
        end

        def end_of_the_line_reached(segment)
          update_line_status_based_on_last_output
          wrap_by_char(segment) unless @disable_wrap_by_char || @line_contains_more_than_one_word
          @line_full = true
        end

        def wrap_by_char(segment)
          segment.each_char do |character|
            character_width = @document.width_of(character)
            break unless @accumulated_width + character_width <= @width

            @accumulated_width += character_width
            @fragment_output << character
          end
        end
      end
    end
  end
end
