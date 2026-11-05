# frozen_string_literal: true

module Prawn
  module Text
    NBSP = " "
    ZWSP = "​"
    SHY = "­"

    VALID_OPTIONS = %i[kerning size style].freeze
    MODES = {fill: 0, stroke: 1, fill_stroke: 2, invisible: 3, fill_clip: 4, stroke_clip: 5, fill_stroke_clip: 6, clip: 7}.freeze

    class BadFontFamily < StandardError
      def initialize(message = "Bad font family")
        super
      end
    end

    def text(string, options = {})
      return false if string.nil?

      options = options.dup
      inline_format = options.delete(:inline_format)
      array =
        if inline_format
          text_formatter.format(string, *(inline_format.is_a?(Array) ? inline_format : []))
        else
          [{text: string}]
        end
      formatted_text(array, options)
    end

    def formatted_text(array, options = {})
      options = inspect_options_for_text(options.dup)
      color = options.delete(:color)
      array = array.map { |fragment| fragment[:color] ? fragment : fragment.merge(color:) } if color

      if @indent_paragraphs
        text_formatter.array_paragraphs(array).each do |paragraph|
          remaining_text = draw_indented_formatted_line(paragraph, options)
          if @no_text_printed && !@all_text_printed
            @bounding_box.move_past_bottom
            remaining_text = draw_indented_formatted_line(paragraph, options)
          end
          next if @all_text_printed

          remaining_text = fill_formatted_text_box(remaining_text, options)
          draw_remaining_formatted_text_on_new_pages(remaining_text, options)
        end
      else
        remaining_text = fill_formatted_text_box(array, options)
        draw_remaining_formatted_text_on_new_pages(remaining_text, options)
      end
    end

    def text_box(string, options = {})
      options = options.dup
      options[:document] = self
      inline_format = options.delete(:inline_format)
      box =
        if inline_format
          Formatted::Box.new(text_formatter.format(string, *(inline_format.is_a?(Array) ? inline_format : [])), options)
        else
          Box.new(string, options)
        end
      box.render
    end

    def formatted_text_box(array, options = {})
      Formatted::Box.new(array, options.merge(document: self)).render
    end

    def height_of(string, options = {})
      height_of_formatted([{text: string}], options)
    end

    def height_of_formatted(array, options = {})
      raise NotImplementedError, ":indent_paragraphs option not available with height_of" if options[:indent_paragraphs]

      process_final_gap_option(options)
      box = Formatted::Box.new(array, options.merge(height: 100_000_000, document: self))
      box.render(dry_run: true)
      @final_gap ? box.height + box.line_gap + box.leading : box.height
    end

    def draw_text(text, options)
      options = inspect_options_for_draw_text(options.dup)
      text = text.to_s.dup
      save_font do
        process_text_options(options)
        text = font.normalize_encoding(text)
        font_size(options[:size]) { draw_text!(text, options) }
      end
    end

    def draw_text!(text, options)
      unless font.unicode? || font.class.hide_m17n_warning || text.ascii_only?
        warn "PDF's built-in fonts have very limited support for internationalized text.\n" \
          "If you need full UTF-8 support, consider using an external font instead.\n\n" \
          "To disable this warning, add the following line to your code:\nPrawn::Fonts::AFM.hide_m17n_warning = true\n"
        font.class.hide_m17n_warning = true
      end
      x, y = map_to_absolute(options[:at])
      add_text_content(text, x, y, options)
    end

    def process_text_options(options)
      if options[:style]
        raise BadFontFamily unless font.family

        font(font.family, style: options[:style])
      end
      options[:kerning] = font.has_kerning_data? unless options[:kerning] == false
      options[:size] ||= font_size
    end

    def default_kerning?
      return true unless defined?(@default_kerning)

      @default_kerning
    end

    def default_kerning(value)
      @default_kerning = value
    end
    alias_method :default_kerning=, :default_kerning

    def default_leading(number = nil)
      return @default_leading || 0 if number.nil?

      @default_leading = number
    end
    alias_method :default_leading=, :default_leading

    def text_direction(direction = nil)
      return @text_direction || :ltr if direction.nil?

      @text_direction = direction
    end
    alias_method :text_direction=, :text_direction

    def fallback_fonts(fallback_fonts = nil)
      return @fallback_fonts || [] if fallback_fonts.nil?

      @fallback_fonts = fallback_fonts
    end
    alias_method :fallback_fonts=, :fallback_fonts

    def text_rendering_mode(mode = nil, &)
      return @text_rendering_mode || :fill if mode.nil?
      raise ArgumentError, "mode must be between one of #{MODES.keys.join(", ")} (#{mode})" unless MODES.key?(mode)
      return yield if text_rendering_mode == mode

      wrap_and_restore(:text_rendering_mode, :@text_rendering_mode, mode, &)
    end

    def forget_text_rendering_mode!
      @text_rendering_mode = :unknown
    end

    def character_spacing(amount = nil, &)
      return @character_spacing || 0 if amount.nil?
      return yield if character_spacing == amount

      wrap_and_restore(:character_spacing, :@character_spacing, amount, &)
    end

    def word_spacing(amount = nil, &)
      return @word_spacing || 0 if amount.nil?
      return yield if word_spacing == amount

      wrap_and_restore(:word_spacing, :@word_spacing, amount, &)
    end

    def horizontal_text_scaling(amount = nil, &)
      return @horizontal_text_scaling || 100 if amount.nil?
      return yield if horizontal_text_scaling == amount

      wrap_and_restore(:horizontal_text_scaling, :@horizontal_text_scaling, amount, &)
    end

    def rise(amount = nil, &)
      return @rise || 0 if amount.nil?
      return yield if rise == amount

      wrap_and_restore(:rise, :@rise, amount, &)
    end

    def add_text_content(text, x, y, options)
      chunks = font.encode_text(text, options.merge(word_spacing:, font_size:))
      add_content("\nBT")
      if options[:rotate]
        radians = Float(options[:rotate]) * Math::PI / 180
        add_content("#{PDF::Core.real_params([Math.cos(radians), Math.sin(radians), -Math.sin(radians), Math.cos(radians), x, y])} Tm")
      else
        add_content("#{PDF::Core.real(x)} #{PDF::Core.real(y)} Td")
      end
      chunks.each do |subset, string|
        font.add_to_current_page(subset)
        add_content("#{PDF::Core.serialize(font.identifier_for(subset), true)} #{PDF::Core.serialize(font_size, true)} Tf")
        operator = string.is_a?(Array) ? "TJ" : "Tj"
        add_content("#{PDF::Core.serialize(string, true)} #{operator}")
      end
      add_content("ET\n")
    end

    private

    def draw_remaining_formatted_text_on_new_pages(remaining_text, options)
      until remaining_text.empty?
        @bounding_box.move_past_bottom
        previous_remaining_text = remaining_text
        remaining_text = fill_formatted_text_box(remaining_text, options)
        break if remaining_text == previous_remaining_text
      end
    end

    def draw_indented_formatted_line(string, options)
      gap = (options.fetch(:direction, text_direction) == :ltr) ? [@indent_paragraphs, 0] : [0, @indent_paragraphs]
      indent(*gap) { fill_formatted_text_box(string, options.merge(single_line: true)) }
    end

    def fill_formatted_text_box(text, options)
      merge_text_box_positioning_options(options)
      box = Formatted::Box.new(text, options)
      remaining_text = box.render
      @no_text_printed = box.nothing_printed?
      @all_text_printed = box.everything_printed?
      self.y -= box.height
      self.y -= box.line_gap + box.leading if @final_gap || (options[:single_line] && !@all_text_printed)
      remaining_text
    end

    def merge_text_box_positioning_options(options)
      bottom = @bounding_box.stretchy? ? @margin_box.absolute_bottom : @bounding_box.absolute_bottom
      options[:height] = y - bottom
      options[:width] = bounds.width
      options[:at] = [@bounding_box.left_side - @bounding_box.absolute_left, y - @bounding_box.absolute_bottom]
    end

    def inspect_options_for_text(options)
      raise ArgumentError, ":at is no longer a valid option with text.use draw_text or text_box instead" if options[:at]

      process_final_gap_option(options)
      @indent_paragraphs = options.delete(:indent_paragraphs)
      options[:document] = self
      options
    end

    def process_final_gap_option(options)
      @final_gap = options[:final_gap].nil? || options[:final_gap]
      options.delete(:final_gap)
    end

    def move_text_position(amount)
      bottom = @bounding_box.stretchy? ? @margin_box.absolute_bottom : @bounding_box.absolute_bottom
      @bounding_box.move_past_bottom if (y - amount) < bottom
      self.y -= amount
    end

    def wrap_and_restore(setting, variable, value)
      original_value = instance_variable_get(variable)
      instance_variable_set(variable, value)
      write_text_state(setting, value)
      begin
        yield
      ensure
        instance_variable_set(variable, original_value)
        write_text_state(setting, public_send(setting))
      end
    end

    # Writes a text state parameter, and records it in the graphic state it now belongs to. A text rendering mode
    # forgotten by forget_text_rendering_mode! is unknown: nothing to write, and the state keeps the mode in effect.
    def write_text_state(setting, value)
      return if value == :unknown

      add_content(
        case setting
        when :text_rendering_mode then "\n#{MODES[value]} Tr"
        when :character_spacing then "\n#{PDF::Core.real(value)} Tc"
        when :word_spacing then "\n#{PDF::Core.real(value)} Tw"
        when :horizontal_text_scaling then "\n#{PDF::Core.real(value)} Tz"
        when :rise then "\n#{PDF::Core.real(value)} Ts"
        end
      )
      page.stack.last.public_send(PDF::Core::GraphicState::TEXT_STATE_WRITERS[setting], value)
    end

    # The text state parameters are part of the graphic state (ISO 32000-1 §9.3.1): a new page starts without them, and
    # a restore closing a state opened on the page returns to that state's. Write back those of the blocks still open
    # that the current state lacks.
    def resume_text_state
      current = page.stack.last
      PDF::Core::GraphicState::DEFAULT_TEXT_STATE.each do |setting, default|
        written = current ? current.public_send(setting) : default
        value = public_send(setting)
        write_text_state(setting, value) unless value == written
      end
    end

    def inspect_options_for_draw_text(options)
      raise ArgumentError, "The :at option is required for draw_text" if options[:at].nil?
      raise ArgumentError, "The :align option does not work with draw_text" if options[:align]

      options[:kerning] = default_kerning? if options[:kerning].nil?
      Prawn.verify_options(VALID_OPTIONS + %i[at rotate], options)
      options
    end
  end
end
