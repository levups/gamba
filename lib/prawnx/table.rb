# frozen_string_literal: true

module Prawn
  module Errors
    InvalidTableData = Class.new(StandardError)
    EmptyTable = Class.new(StandardError)
  end

  # A table of cells laid out in rows and columns, sized to its content, drawn across pages with its header
  # repeated: prawn-table's API.
  class Table
    module Interface
      def table(data, options = {}, &)
        table = Table.new(data, self, options, &)
        table.draw
        table
      end

      def make_table(data, options = {}, &)
        Table.new(data, self, options, &)
      end
    end

    attr_reader :row_length, :column_length, :cells
    attr_writer :width, :position, :header, :row_colors

    def initialize(data, document, options = {}, &block)
      @pdf = document
      @cells = make_cells(data)
      @header = false
      options.each { |key, value| send(:"#{key}=", value) }
      if block
        (block.arity < 1) ? instance_eval(&block) : yield(self)
      end
      set_column_widths
      set_row_heights
      position_cells
    end

    def before_rendering_page(&block)
      @before_rendering_page = block
    end

    def width
      @width ||= [natural_width, @pdf.bounds.width].min
    end

    def column_widths=(widths)
      case widths
      when Array then widths.each_with_index { |width, index| column(index).width = width }
      when Hash then widths.each { |index, width| column(index).width = width }
      when Numeric then cells.width = widths
      else raise ArgumentError, "cannot interpret column widths"
      end
    end

    def height
      cells.height
    end

    def cell_style=(style_hash)
      cells.style(style_hash)
    end

    def style(stylable, style_hash = {}, &)
      stylable.style(style_hash, &)
    end

    def rows(row_spec)
      cells.rows(row_spec)
    end
    alias_method :row, :rows

    def columns(column_spec)
      cells.columns(column_spec)
    end
    alias_method :column, :columns

    def draw
      with_position do
        reference_bounds = @pdf.reference_bounds
        started_new_page_at_row = initial_row_on_initial_page
        offset = @pdf.y
        @header_row = header_rows if @header
        cells_this_page = []
        @cells.each do |cell|
          if start_new_page?(cell, offset, reference_bounds)
            cells_this_page, offset = ink_and_draw_cells_and_start_new_page(cells_this_page, cell)
            started_new_page_at_row = cell.row
          end
          cell = set_background_color(cell, started_new_page_at_row)
          cells_this_page << [cell, [cell.relative_x, cell.relative_y(offset)]]
        end
        ink_and_draw_cells(cells_this_page)
        @pdf.move_cursor_to(@cells.last.relative_y(offset) - @cells.last.height)
      end
    end

    def column_widths
      @column_widths ||= begin
        if width - cells.min_width < -FLOAT_PRECISION
          raise Errors::CannotFit, "Table's width was set too small to contain its contents (min width #{cells.min_width}, requested #{width})"
        end
        if width - cells.max_width > FLOAT_PRECISION
          raise Errors::CannotFit, "Table's width was set larger than its contents' maximum width (max width #{cells.max_width}, requested #{width})"
        end

        if width - natural_width < -FLOAT_PRECISION
          ratio = (width - cells.min_width).to_f / (natural_width - cells.min_width)
          (0...column_length).map do |index|
            minimum = column(index).min_width
            (ratio * (natural_column_widths[index] - minimum)) + minimum
          end
        elsif width - natural_width > FLOAT_PRECISION
          ratio = (width - cells.width).to_f / (cells.max_width - cells.width)
          (0...column_length).map do |index|
            natural = natural_column_widths[index]
            (ratio * (column(index).max_width - natural)) + natural
          end
        else
          natural_column_widths
        end
      end
    end

    def row_heights
      @natural_row_heights ||= begin
        heights_by_row = Hash.new(0)
        cells.each do |cell|
          next if cell.is_a?(Cell::SpanDummy)

          height_per_row = cell.height.to_f / cell.rowspan
          cell.rowspan.times { heights_by_row[cell.row + it] = [heights_by_row[cell.row + it], height_per_row].max }
        end
        heights_by_row.sort_by { |row, _| row }.map { |_, height| height }
      end
    end

    protected

    def set_background_color(cell, started_new_page_at_row)
      if @row_colors && (!@header || cell.row.positive?)
        index = cell.row - [started_new_page_at_row, number_of_header_rows].max
        cell.background_color ||= @row_colors[index % @row_colors.length]
      end
      cell
    end

    def number_of_header_rows
      return @header if @header.is_a?(Integer)

      @header ? 1 : 0
    end

    def start_new_page?(cell, offset, reference_bounds)
      cell.column.zero? && cell.row.positive? && !row(cell.row).fits_on_current_page?(offset, reference_bounds)
    end

    def ink_and_draw_cells(cells_this_page, draw_cells = true)
      ink_cells(cells_this_page)
      Cell.draw_cells(cells_this_page) if draw_cells
    end

    def ink_and_draw_cells_and_start_new_page(cells_this_page, cell)
      ink_and_draw_cells(cells_this_page, @header_row.nil? || cells_this_page.size > @header_row.size)
      @pdf.bounds.move_past_bottom
      offset = @pdf.y - cell.y
      cells_next_page = []
      offset -= add_header(cell.row, cells_next_page)
      [cells_next_page, offset]
    end

    def ink_cells(cells_this_page)
      @before_rendering_page&.call(Cells.new(cells_this_page.map(&:first)))
    end

    def initial_row_on_initial_page
      return 0 if fits_on_page?(@pdf.bounds.height)
      return -1 if fits_on_page?(row(0..number_of_header_rows).height, true)

      @pdf.bounds.move_past_bottom
      0
    end

    def fits_on_page?(needed_height, use_reference_bounds = false)
      bounds = use_reference_bounds ? @pdf.reference_bounds : @pdf.bounds
      needed_height < @pdf.y - (bounds.absolute_bottom - FLOAT_PRECISION)
    end

    def header_rows
      header_rows = Cells.new
      number_of_header_rows.times do |row_index|
        row(row_index).each { header_rows[it.row, it.column] = it.dup }
      end
      header_rows
    end

    def make_cells(data)
      assert_proper_table_data(data)
      cells = Cells.new
      data.each_with_index do |row_cells, row_number|
        column_number = 0
        row_cells.each do |cell_data|
          column_number += 1 until cells[row_number, column_number].nil?
          cell = Cell.make(@pdf, cell_data)
          cells[row_number, column_number] = cell
          cell.rowspan.times do |row_offset|
            cell.colspan.times do |column_offset|
              next if row_offset.zero? && column_offset.zero?
              if cells[row_number + row_offset, column_number + column_offset]
                raise Errors::InvalidTableSpan, "Spans overlap at row #{row_number + row_offset}, column #{column_number + column_offset}."
              end

              dummy = Cell::SpanDummy.new(@pdf, cell)
              cells[row_number + row_offset, column_number + column_offset] = dummy
              cell.dummy_cells << dummy
            end
          end
          column_number += cell.colspan
        end
      end
      @row_length = cells.map { it.row + it.rowspan }.max
      @column_length = cells.map { it.column + it.colspan }.max
      cells
    end

    def add_header(row_number, cells_this_page)
      x_offset = @pdf.bounds.left_side - @pdf.bounds.absolute_left
      header_height = 0
      if row_number.positive? && @header
        y = @pdf.cursor
        number_of_header_rows.times do |header_index|
          header_height += add_one_header_row(cells_this_page, x_offset, y - header_height, row_number - 1, header_index)
        end
      end
      header_height
    end

    def add_one_header_row(page_of_cells, x_offset, y, row, row_of_header = nil)
      rows_to_operate_on = row_of_header ? @header_row.rows(row_of_header) : @header_row
      rows_to_operate_on.each do |cell|
        cell.row = row
        cell.dummy_cells.each { (cell.rowspan > 1) ? it.row += row : it.row = row }
        page_of_cells << [cell, [cell.x + x_offset, y]]
      end
      rows_to_operate_on.height
    end

    def assert_proper_table_data(data)
      if data.nil? || data.empty?
        raise Errors::EmptyTable, "data must be a non-empty, non-nil, two dimensional array of cell-convertible objects"
      end
      raise Errors::InvalidTableData, "data must be a two dimensional array of cellable objects" unless data.all?(Array)
    end

    def natural_column_widths
      @natural_column_widths ||= ColumnWidthCalculator.new(cells).natural_widths
    end

    def natural_width
      @natural_width ||= natural_column_widths.sum
    end

    def set_column_widths
      column_widths.each_with_index { |width, index| column(index).width = width }
    end

    def set_row_heights
      row_heights.each_with_index { |height, index| row(index).height = height }
    end

    def position_cells
      column_widths.each_with_object([0]) { |width, positions| positions << (positions.last + width) }[0..-2]
        .each_with_index { |x, index| column(index).x = x }
      row_heights.each_with_object([0]) { |height, positions| positions << (positions.last - height) }[0..-2]
        .each_with_index { |y, index| row(index).y = y }
    end

    def with_position
      x =
        case @position || :left
        when :left then return yield
        when :center then (@pdf.bounds.width - width) / 2.0
        when :right then @pdf.bounds.width - width
        when Numeric then @position
        else raise ArgumentError, "unknown position #{@position.inspect}"
        end
      dy = @pdf.bounds.absolute_top - @pdf.y
      final_y = nil
      @pdf.bounding_box([x, @pdf.bounds.top], width:) do
        @pdf.move_down dy
        yield
        final_y = @pdf.y
      end
      @pdf.y = final_y
    end
  end
end
