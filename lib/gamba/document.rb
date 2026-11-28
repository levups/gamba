# frozen_string_literal: true

module Prawn
  class Document
    include Internals
    include Graphics
    include Text
    include TransformationStack
    include PDF::Core::Annotations
    include Gamba::Forms
    include Gamba::Signing
    include PDF::Core::Destinations
    include Security
    include Images
    include Barcodes
    include Gamba::PdfA
    include Gamba::Tagging
    include Table::Interface
    include Stamp
    include SoftMask

    VALID_OPTIONS = %i[
      page_size page_layout margin left_margin right_margin top_margin bottom_margin skip_page_creation compress
      background info text_formatter print_scaling pdf_a pdf lang background_pdf background_pdf_page watermark bleed crop_marks
    ].freeze
    # Room for crop marks beyond the bleed, and the gap that keeps them off it.
    CROP_MARK_SLUG = 18
    CROP_MARK_GAP = 3

    attr_accessor :margin_box, :page_number, :text_formatter
    # The font used until one is set, Helvetica unless told: PDF/A and PDF/UA documents of Gamba's own API take
    # their default style's.
    attr_accessor :default_font_family
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
      @pdf_a_conformance = Gamba::PdfA.conformance(options.delete(:pdf_a))
      initialize_tagging(options)
      @background = options[:background]
      @background_scale = options[:background_scale] || 1
      @background_pdf = options[:background_pdf]
      @background_pdf_page = options[:background_pdf_page] || 1
      @gamba_watermark = Gamba::Watermark.from_option(options[:watermark], pdf_a: pdf_a?)
      @bleed = options.fetch(:bleed, 0)
      raise ArgumentError, "bleed is #{@bleed.inspect}: give it in points, such as 9 (3 mm)" unless @bleed.is_a?(Numeric) && @bleed >= 0
      @crop_marks = options[:crop_marks] ? true : false
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
      close_marks_on_page
      last_page = page
      page_options = {size: options[:size] || last_page&.size, layout: options[:layout] || last_page&.layout, margins: last_page&.margins&.dup,
                      bleed: @bleed, slug: @crop_marks ? CROP_MARK_SLUG : 0}
      if last_page
        new_graphic_state = last_page.graphic_state&.dup
        new_graphic_state&.color_space = {}
        last_blend_mode = new_graphic_state&.blend_mode
        new_graphic_state&.blend_mode = nil
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
      tag_artifact { canvas { image(@background, scale: @background_scale, at: bounds.top_left) } } if @background
      draw_background_pdf(options)
      draw_crop_marks if @crop_marks
      @gamba_watermark&.open_page(self)
      @y = @bounding_box.absolute_top
      float { tag_artifact { @on_page_create&.call(self) } }
      header_blend_mode = page.stack.last&.blend_mode
      reopen_ext_gstate_blocks
      # The blend mode in effect on the last page, which the new one resets to Normal (ISO 32000-1 §8.4.1), once the
      # blocks still open are reopened, unless the page's header set one of its own.
      return if header_blend_mode || graphic_state.blend_mode == last_blend_mode

      write_ext_gstate(last_blend_mode || blend_mode_ext_gstate(:Normal))
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
      close_marks_on_page
      @page_number = page_number
      @page = pages[page_number - 1]
      generate_margin_box
      @y = @bounding_box.absolute_top
      close_restored_graphics_states
      reopen_ext_gstate_blocks_on_existing_page
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
      @gamba_watermark&.fill_stamps(self)
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

    # Gamba's own API on this document, from the cursor where it stands: gamba { |document| document.text "…" }.
    def gamba
      @gamba ||= Gamba::Document.new(self)
      if block_given?
        yield @gamba
        # Boxes kept with a next one the block never added are placed before Prawn's code goes on.
        @gamba.prawn
      end
      @gamba
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

    # A page of another PDF under each page, at its own size from the top left corner: the document's, unless
    # start_new_page names another (background_pdf:, background_pdf_page:) or none (background_pdf: false).
    def draw_background_pdf(options)
      source, number = options.key?(:background_pdf) ? [options[:background_pdf], options[:background_pdf_page] || 1] : [@background_pdf, @background_pdf_page]
      tag_artifact { canvas { pdf_page(source, page: number, at: bounds.top_left) } } if source
    end

    # Crop marks at each corner of the trimmed page, in its slug, off the bleed: hairlines in the registration colour,
    # which prints on every plate.
    def draw_crop_marks
      _left, _bottom, width, height = page.dimensions
      (page.resources[:ColorSpace] ||= {})[:CSAll] ||= registration_color_space
      near = @bleed + CROP_MARK_GAP
      far = @bleed + CROP_MARK_SLUG
      lines = [[0, 0, -1, 0], [0, 0, 0, -1], [width, 0, 1, 0], [width, 0, 0, -1], [0, height, -1, 0], [0, height, 0, 1], [width, height, 1, 0], [width, height, 0, 1]]
      paths = lines.map do |x, y, dx, dy|
        "#{PDF::Core.real_params([x + (dx * near), y + (dy * near)])} m #{PDF::Core.real_params([x + (dx * far), y + (dy * far)])} l"
      end
      tag_artifact { save_graphics_state { add_content("/CSAll CS 1 SCN 0.25 w 0 J\n#{paths.join("\n")}\nS") } }
    end

    # The colour space of all the plates at once (ISO 32000-1 §8.6.6.4), shown black where there are none.
    def registration_color_space
      @registration_color_space ||= ref!([:Separation, :All, :DeviceGray, {FunctionType: 2, Domain: [0, 1], C0: [1], C1: [0], N: 1}])
    end

    # A gradient set as the fill or stroke stays it on the new page, in place of the colour Prawn writes.
    def use_graphic_settings(override_settings = false)
      write_fill_paint if graphic_state.fill_pattern || current_fill_color != "000000" || override_settings
      write_stroke_paint if graphic_state.stroke_pattern || current_stroke_color != "000000" || override_settings
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
