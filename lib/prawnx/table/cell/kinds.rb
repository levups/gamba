# frozen_string_literal: true

module Prawn
  class Table
    class Cell
      class Text < Cell
        TextOptions = %i[inline_format kerning size align valign rotate rotate_around leading single_line skip_encoding overflow min_font_size].freeze # rubocop:disable Naming/ConstantName -- Prawn::Table's public name

        TextOptions.each do |option|
          define_method(:"#{option}=") { |value| @text_options[option] = value }
          define_method(option) { @text_options[option] }
        end

        attr_writer :font, :text_color

        def initialize(pdf, point, options = {})
          @text_options = {}
          super
        end

        def font
          with_font { @pdf.font }
        end

        def font_style=(style)
          @text_options[:style] = style
        end

        def natural_content_width
          @natural_content_width ||= [styled_width_of(@content), @pdf.bounds.width].min
        end

        def natural_content_height
          with_font do
            @laid_out_box = text_box(width: spanned_content_width + FPTolerance)
            @laid_out_box.render(dry_run: true, keep_layout: true)
            @layout_inputs = layout_inputs
            @laid_out_box.height + @laid_out_box.line_gap
          end
        end

        def draw_content
          with_font do
            @pdf.move_down((@pdf.font.line_gap + @pdf.font.descender) / 2)
            with_text_color do
              if laid_out_box_reusable?
                @laid_out_box.render_laid_out([0, @pdf.cursor])
              else
                text_box(width: spanned_content_width + FPTolerance, height: spanned_content_height + FPTolerance, at: [0, @pdf.cursor]).render
              end
            end
          end
        end

        def set_width_constraints
          unless @min_width
            @min_width = padding_left + padding_right + [natural_content_width, styled_width_of("M")].min
            super
          end
        end

        protected

        def with_font
          @pdf.save_font do
            options = {}
            options[:style] = @text_options[:style] if @text_options[:style]
            options[:style] ||= @pdf.font.options[:style] if @pdf.font.options[:style]
            @pdf.font(@font || @pdf.font.family, options)
            yield
          end
        end

        def with_text_color
          return yield unless @text_color

          begin
            old_color = @pdf.fill_color || "000000"
            @pdf.fill_color(@text_color)
            yield
          ensure
            @pdf.fill_color(old_color)
          end
        end

        def text_box(extra_options = {})
          inline_format = @text_options[:inline_format]
          if inline_format
            options = @text_options.except(:inline_format).merge(extra_options).merge(document: @pdf)
            array = @pdf.text_formatter.format(@content, *(inline_format.is_a?(Array) ? inline_format : []))
            Prawn::Text::Formatted::Box.new(array, options)
          else
            Prawn::Text::Box.new(@content, @text_options.merge(extra_options).merge(document: @pdf))
          end
        end

        def styled_width_of(text)
          @pdf.width_of(text, @text_options)
        end

        private

        # A cell is laid out while the table is sized, then drawn: the layout is drawn again unless
        # before_rendering_page, the document or a truncating height changed what the cell would wrap.
        def laid_out_box_reusable?
          @laid_out_box&.layout_reusable? && @laid_out_box.height <= spanned_content_height + FPTolerance &&
            @layout_inputs == layout_inputs
        end

        def layout_inputs
          [@content.dup, spanned_content_width, @text_options.dup, @pdf.font, @pdf.font_size, @pdf.default_leading,
            @pdf.character_spacing, @pdf.text_direction, @pdf.fallback_fonts, @pdf.default_kerning?]
        end
      end

      class Subtable < Cell
        attr_reader :subtable

        def initialize(pdf, point, options = {})
          super
          @subtable = options[:content]
          @padding = [0, 0, 0, 0]
        end

        def text_color=(color)
          @subtable.cells.text_color = color
        end

        def natural_content_width
          @subtable.cells.width
        end

        def min_width
          @subtable.cells.min_width
        end

        def max_width
          @subtable.cells.max_width
        end

        def natural_content_height
          @subtable.cells.height
        end

        def draw_content
          @subtable.draw
        end
      end

      class Image < Cell
        def initialize(pdf, point, options = {})
          @image_options = {}
          super
          @pdf_object, @image_info = @pdf.build_image_object(@file)
          @natural_width, @natural_height = @image_info.calc_image_dimensions(@image_options)
        end

        def image=(file)
          @file = file
        end

        {scale: :scale, fit: :fit, image_height: :height, image_width: :width, position: :position, vposition: :vposition}.each do |setter, option|
          define_method(:"#{setter}=") { |value| @image_options[option] = value }
        end

        def natural_content_width
          @natural_width
        end

        def natural_content_height
          @natural_height
        end

        def draw_content
          @pdf.embed_image(@pdf_object, @image_info, @image_options)
        end
      end

      # Stands in the place a spanning cell covers beyond its first row and column, passing on the styles of
      # its right and bottom edges.
      class SpanDummy < Cell
        def initialize(pdf, master_cell)
          super(pdf, [0, pdf.cursor])
          @master_cell = master_cell
          @padding = [0, 0, 0, 0]
        end

        def natural_content_height
          0
        end

        def natural_content_width
          0
        end

        def avg_spanned_min_width
          @master_cell.avg_spanned_min_width
        end

        def draw_borders(_point)
        end

        def draw_bounded_content(_point)
        end

        def padding_right=(value)
          @master_cell.padding_right = value if rightmost?
        end

        def padding_bottom=(value)
          @master_cell.padding_bottom = value if bottommost?
        end

        def border_right_color=(value)
          @master_cell.border_right_color = value if rightmost?
        end

        def border_bottom_color=(value)
          @master_cell.border_bottom_color = value if bottommost?
        end

        def border_right_width=(value)
          @master_cell.border_right_width = value if rightmost?
        end

        def border_bottom_width=(value)
          @master_cell.border_bottom_width = value if bottommost?
        end

        def background_color
          @master_cell.background_color
        end

        private

        def rightmost?
          @column == @master_cell.column + @master_cell.colspan - 1
        end

        def bottommost?
          @row == @master_cell.row + @master_cell.rowspan - 1
        end
      end
    end
  end
end
