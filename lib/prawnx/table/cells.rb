# frozen_string_literal: true

module Prawn
  class Table
    # A selection of a table's cells, addressable by row and column, styled all at once.
    class Cells < Array
      def fits_on_current_page?(offset, reference_bounds)
        return true if empty?

        height_with_span < (self[0, 0].y + offset) - reference_bounds.absolute_bottom
      end

      def rows(row_spec)
        index_cells unless @indexed
        row_spec = transform_spec(row_spec, @first_row, @row_count)
        Cells.new(@rows[row_spec] ||= select { row_spec.respond_to?(:include?) ? row_spec.include?(it.row) : row_spec === it.row })
      end
      alias_method :row, :rows

      def row_count
        index_cells unless @indexed
        @row_count
      end

      def columns(column_spec)
        index_cells unless @indexed
        column_spec = transform_spec(column_spec, @first_column, @column_count)
        Cells.new(@columns[column_spec] ||= select { column_spec.respond_to?(:include?) ? column_spec.include?(it.column) : column_spec === it.column })
      end
      alias_method :column, :columns

      def column_count
        index_cells unless @indexed
        @column_count
      end

      def filter(&)
        Cells.new(select(&))
      end

      def [](row, column)
        return nil if empty?

        index_cells unless @indexed
        row_cells = @rows[@first_row + row] || []
        column_cells = @columns[@first_column + column] || []
        if row_cells.length < column_cells.length
          row_cells.find { it.column == @first_column + column }
        else
          column_cells.find { it.row == @first_row + row }
        end
      end

      def []=(row, column, cell)
        cell.extend(Cell::InTable)
        cell.row = row
        cell.column = column
        if @indexed
          (@rows[row] ||= []) << cell
          (@columns[column] ||= []) << cell
          @first_row = row if !@first_row || row < @first_row
          @first_column = column if !@first_column || column < @first_column
          @row_count = @rows.size
          @column_count = @columns.size
        end
        self << cell
      end

      def style(options = {}, &)
        each { it.style(options, &) unless it.is_a?(Cell::SpanDummy) }
      end

      def width
        ColumnWidthCalculator.new(self).natural_widths.sum
      end

      def min_width
        aggregate_cell_values(:column, :avg_spanned_min_width, :max)
      end

      def max_width
        aggregate_cell_values(:column, :max_width_ignoring_span, :max)
      end

      def height
        aggregate_cell_values(:row, :height_ignoring_span, :max)
      end

      def height_with_span
        aggregate_cell_values(:row, :height, :max)
      end

      # Setters reach every cell that has them: cells.background_color = "eeeeee".
      def method_missing(name, *arguments, &)
        return super unless name.end_with?("=")

        each { it.public_send(name, *arguments, &) if it.respond_to?(name) }
      end

      def respond_to_missing?(name, include_private = false)
        name.end_with?("=") || super
      end

      protected

      def index_cells
        @rows = {}
        @columns = {}
        each do |cell|
          (@rows[cell.row] ||= []) << cell
          (@columns[cell.column] ||= []) << cell
        end
        @first_row = @rows.keys.min
        @first_column = @columns.keys.min
        @row_count = @rows.size
        @column_count = @columns.size
        @indexed = true
      end

      def aggregate_cell_values(row_or_column, method, aggregate)
        ColumnWidthCalculator.new(self).aggregate_cell_values(row_or_column, method, aggregate)
      end

      def transform_spec(spec, first, total)
        case spec
        when Range then transform_spec(spec.begin, first, total)..transform_spec(spec.end, first, total)
        when Integer then spec.negative? ? first + total + spec : first + spec
        when Enumerable then spec.map { first + it }
        else raise "Don't understand spec #{spec.inspect}"
        end
      end
    end

    # Widths of columns, and sums of per-row or per-column cell values, accounting for cells spanning several.
    class ColumnWidthCalculator
      def initialize(cells)
        @cells = cells
        @widths_by_column = Hash.new(0)
        @rows_with_a_span_dummy = Hash.new(false)
        @cells.each { @rows_with_a_span_dummy[it.row] = true if it.is_a?(Cell::SpanDummy) }
      end

      def has_a_span_dummy?(row)
        @rows_with_a_span_dummy[row]
      end

      def fill_values_if_needed(values, cell, index, method)
        missing_count = cell.colspan.times.count { values[index + it].nil? }
        return values if missing_count.zero? || missing_count == cell.colspan || !has_a_span_dummy?(cell.row)

        new_sum = cell.send(method) * cell.colspan
        cell.colspan.times { new_sum -= values[index + it] unless values[index + it].nil? }
        new_value = new_sum.to_f / missing_count
        cell.colspan.times { values[index + it] = new_value if values[index + it].nil? }
        values
      end

      def natural_widths
        @cells.each do |cell|
          @widths_by_column[cell.column] = [@widths_by_column[cell.column], cell.width.to_f].max unless has_a_span_dummy?(cell.row)
        end
        @cells.each do |cell|
          next unless has_a_span_dummy?(cell.row)
          next if cell.is_a?(Cell::SpanDummy)

          if cell.colspan == 1
            @widths_by_column[cell.column] = [@widths_by_column[cell.column], cell.width.to_f].max
          else
            current_width_of_spanned_cells = @widths_by_column.to_a[cell.column..(cell.column + cell.colspan - 1)].sum(&:last)
            if (cell.width.to_f - current_width_of_spanned_cells) > FLOAT_PRECISION
              cell.colspan.times { @widths_by_column[cell.column + it] = cell.width.to_f / cell.colspan }
            end
          end
        end
        @widths_by_column.sort_by { |column, _| column }.map { |_, width| width }
      end

      def aggregate_cell_values(row_or_column, method, aggregate)
        values = {}
        @cells.each do |cell|
          next unless cell.colspan == 1 && cell.class != Cell::SpanDummy

          index = cell.send(row_or_column)
          values[index] = [values[index], cell.send(method)].compact.send(aggregate)
        end

        spanned_width_needs_fixing = true
        @cells.each do |cell|
          index = cell.send(row_or_column)
          if cell.colspan > 1
            values = fill_values_if_needed(values, cell, index, method) if row_or_column == :column
            old_sum = cell.colspan.times.inject(0) { |sum, offset| values[index + offset] ? sum + values[index + offset] : sum }
            new_sum = cell.send(method) * cell.colspan
            spanned_width_needs_fixing = (new_sum - old_sum) > FLOAT_PRECISION
            if spanned_width_needs_fixing
              values[index] = [values[index], cell.send(method)].compact.send(aggregate)
              entries_exist = cell.colspan.times.none? { values[index + it].nil? }
              cell.colspan.times { values[index + it] = cell.send(method) if entries_exist }
            end
          elsif spanned_width_needs_fixing && cell.instance_of?(Cell::SpanDummy)
            values[index] = [values[index], cell.send(method)].compact.send(aggregate)
          end
        end
        values.values.sum
      end
    end
  end
end
