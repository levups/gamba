# frozen_string_literal: true

module Prawn
  class Document
    include Internals
    include Graphics
    include Text
    include TransformationStack
    include PDF::Core::Annotations
    include PDF::Core::Destinations
    include Security
    include Images
    include PrawnX::PdfA
    include Table::Interface
    include Stamp
    include SoftMask

    VALID_OPTIONS = %i[
      page_size page_layout margin left_margin right_margin top_margin bottom_margin skip_page_creation compress
      background info text_formatter print_scaling pdf_a
    ].freeze

    attr_accessor :margin_box, :page_number, :text_formatter
    attr_reader :margins, :y

    # Modules every new document extends itself with: a subclass starts with its parent's.
    def self.extensions
      @extensions ||= []
    end

    def self.inherited(subclass)
      super
      subclass.extensions.concat(extensions)
    end

    def self.generate(filename, options = {}, &)
      new(options, &).render_file(filename)
    end

    def initialize(options = {}, &block)
      options = options.dup
      Prawn.verify_options(VALID_OPTIONS, options)
      self.class.extensions.reverse_each { extend(_1) }

      initialize_internals(options)
      @pdf_a = options.delete(:pdf_a) == true
      @background = options[:background]
      @background_scale = options[:background_scale] || 1
      @font_size = 12
      @bounding_box = nil
      @margin_box = nil
      @page_number = 0
      @text_formatter = options.delete(:text_formatter) || Text::Formatted::Parser
      options[:size] = options.delete(:page_size)
      options[:layout] = options.delete(:page_layout)

      initialize_first_page(options)
      @bounding_box = @margin_box

      return unless block

      (block.arity < 1) ? instance_eval(&block) : yield(self)
    end

    def start_new_page(options = {})
      last_page = page
      page_options = {size: options[:size] || last_page&.size, layout: options[:layout] || last_page&.layout, margins: last_page&.margins&.dup}
      if last_page
        new_graphic_state = last_page.graphic_state&.dup
        new_graphic_state&.color_space = {}
        new_graphic_state&.reset_text_state
        page_options[:graphic_state] = new_graphic_state
      end

      @page = PDF::Core::Page.new(self, page_options)
      apply_margin_options(options)
      generate_margin_box
      @bounding_box = @margin_box if last_page && (last_page.size != page.size || last_page.layout != page.layout)
      use_graphic_settings
      resume_text_state
      return if options[:orphan]

      insert_page(page, @page_number)
      @page_number += 1
      canvas { image(@background, scale: @background_scale, at: bounds.top_left) } if @background
      @y = @bounding_box.absolute_top
      float { @on_page_create&.call(self) }
      reopen_ext_gstate_blocks
    end

    def delete_page(index)
      return false if index.abs > pages.count - 1

      pages.delete_at(index)
      pages_reference.data[:Kids].delete_at(index)
      pages_reference.data[:Count] -= 1
      @page_number -= 1
      true
    end

    def page_count
      pages.size
    end

    def go_to_page(page_number)
      @page_number = page_number
      @page = pages[page_number - 1]
      generate_margin_box
      @y = @bounding_box.absolute_top
      resume_text_state
    end

    def y=(new_y)
      @y = new_y
      bounds.update_height
    end

    def cursor
      y - bounds.absolute_bottom
    end

    def move_cursor_to(new_y)
      self.y = new_y + bounds.absolute_bottom
    end

    def float
      original_page = page_number
      original_y = y
      yield
      go_to_page(original_page) unless page_number == original_page
      self.y = original_y
    end

    def render(*arguments)
      output = arguments.first
      (1..page_count).each do |page_number|
        go_to_page(page_number)
        repeaters.each { _1.run(page_number) }
      end
      pdf = render_document
      output << pdf if output.respond_to?(:<<)
      pdf
    end

    def svg(data, options = {}, &)
      require "prawn-svg"
      Prawn::SVG::Extension.instance_method(:svg).bind_call(self, data, options, &)
    end

    def render_file(filename)
      File.binwrite(filename, render)
    end

    def bounds
      @bounding_box
    end

    def bounds=(bounding_box)
      @bounding_box = bounding_box
    end

    def reference_bounds
      @bounding_box.reference_bounds
    end

    def move_up(amount)
      self.y += amount
    end

    def move_down(amount)
      self.y -= amount
    end

    def pad_top(amount)
      move_down(amount)
      yield
    end

    def pad_bottom(amount)
      yield
      move_down(amount)
    end

    def pad(amount)
      move_down(amount)
      yield
      move_down(amount)
    end

    def indent(left, right = 0, &)
      bounds.indent(left, right, &)
    end

    def page_match?(page_filter, page_number)
      case page_filter
      when :all then true
      when :odd then page_number.odd?
      when :even then page_number.even?
      when Range, Array then page_filter.include?(page_number)
      when Proc then page_filter.call(page_number)
      end
    end

    def group(*)
      raise NotImplementedError, "Document#group has been disabled because its implementation lead to corrupted documents whenever a page boundary was crossed"
    end

    def transaction
      raise NotImplementedError, "Document#transaction has been disabled because its implementation lead to corrupted documents whenever a page boundary was crossed"
    end

    def initialize_first_page(options)
      start_new_page(options[:skip_page_creation] ? options.merge(orphan: true) : options)
    end

    def repeaters
      @repeaters ||= []
    end

    private

    def use_graphic_settings(override_settings = false)
      set_fill_color if current_fill_color != "000000" || override_settings
      set_stroke_color if current_stroke_color != "000000" || override_settings
      write_line_width if line_width != 1 || override_settings
      write_stroke_cap_style if cap_style != :butt || override_settings
      write_stroke_join_style if join_style != :miter || override_settings
      write_stroke_dash if dashed? || override_settings
    end

    def generate_margin_box
      old_margin_box = @margin_box
      _left, _bottom, page_width, page_height = page.dimensions
      @margin_box = BoundingBox.new(
        self, nil, [page.margins[:left], page_height - page.margins[:top]],
        width: page_width - (page.margins[:left] + page.margins[:right]),
        height: page_height - (page.margins[:top] + page.margins[:bottom])
      )
      if old_margin_box
        @margin_box.add_left_padding(old_margin_box.total_left_padding)
        @margin_box.add_right_padding(old_margin_box.total_right_padding)
      end
      @bounding_box = @margin_box unless @bounding_box&.parent
    end

    MARGIN_POSITIONS_BY_COUNT = {4 => [0, 1, 2, 3], 3 => [0, 1, 2, 1], 2 => [0, 1, 0, 1], 1 => [0, 0, 0, 0], 0 => []}.freeze

    def apply_margin_options(options)
      margin = Array(options[:margin])
      positions = MARGIN_POSITIONS_BY_COUNT[margin.length]
      %i[top right bottom left].zip(positions).each do |side, position|
        new_margin = options[:"#{side}_margin"] || (margin[position] if position)
        page.margins[side] = new_margin if new_margin
      end
    end
  end
end
