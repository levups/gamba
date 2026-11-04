# frozen_string_literal: true

module Prawn
  class Document
    def repeat(page_filter, options = {}, &)
      repeaters << Repeater.new(self, page_filter, options.fetch(:dynamic, false), &)
    end

    def number_pages(string, options = {})
      options = options.dup
      start_count_at = options.delete(:start_count_at)
      page_filter = options.key?(:page_filter) ? options.delete(:page_filter) : :all
      total_pages = options.delete(:total_pages)
      text_color = options.delete(:color)
      options[:height] = 50 unless options.key?(:height)

      counting = false
      pseudo_page = 0
      (1..page_count).each do |page_number|
        unless counting
          pseudo_page =
            case start_count_at
            when String then Integer(start_count_at, 10)
            when (1..) then Integer(start_count_at)
            else 1
            end
        end
        if page_match?(page_filter, page_number)
          go_to_page(page_number)
          fill_color(text_color) unless text_color.nil?
          total_pages = page_count if total_pages.nil?
          text_box(string.gsub("<page>", pseudo_page.to_s).gsub("<total>", total_pages.to_s), options)
          counting = true
        end
        pseudo_page += 1 if counting
      end
    end
  end

  # Content drawn on every page matching a filter when the document renders: stamped once, or drawn again on
  # each page when dynamic.
  class Repeater
    class << self
      attr_writer :count

      def count
        @count ||= 0
      end
    end

    attr_reader :name

    def initialize(document, page_filter, dynamic = false, &block)
      @document = document
      @page_filter = page_filter
      @dynamic = dynamic
      @stamp_name = "prawn_repeater(#{document.repeaters.size})"
      @document.create_stamp(@stamp_name, &block) unless dynamic
      @block = block if dynamic
      @graphic_state = document.page.graphic_state.dup
      Repeater.count += 1
    end

    def match?(page_number)
      @document.page_match?(@page_filter, page_number)
    end

    def run(page_number)
      return unless match?(page_number)
      return @document.stamp(@stamp_name) unless @dynamic
      return unless @block

      @document.save_graphics_state(@graphic_state) do
        @document.__send__(:freeze_stamp_graphics)
        @block.call
      end
    end
  end
end
