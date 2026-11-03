# frozen_string_literal: true

module Prawn
  class Document
    def outline
      @outline ||= Outline.new(self)
    end
  end

  # The document outline (bookmarks): sections holding pages and subsections, each pointing at a page.
  class Outline
    attr_accessor :parent, :prev, :document, :items

    def initialize(document)
      @document = document
      @parent = root
      @prev = nil
      @items = {}
    end

    def page_number
      @document.page_number
    end

    def define(&block)
      instance_eval(&block) if block
    end
    alias_method :update, :define

    def add_subsection_to(title, position = :last, &)
      @parent = items[title] || raise(Errors::UnknownOutlineTitle, "\n No outline item with title: '#{title}' exists in the outline tree")
      @prev = (position == :first) ? nil : @parent.data.last
      insert_section((position == :first) ? @parent.data.first : nil, &)
    end

    def insert_section_after(title, &)
      @prev = items[title] || raise(Errors::UnknownOutlineTitle, "\n No outline item with title: '#{title}' exists in the outline tree")
      @parent = @prev.data.parent
      insert_section(@prev.data.next, &)
    end

    def section(title, options = {}, &)
      add_outline_item(title, options, &)
    end

    def page(options = {})
      raise Errors::RequiredOption, "\nTitle is a required option for page" unless options[:title]

      add_outline_item(options[:title], options)
    end

    private

    def root
      document.outlines_reference
    end

    def add_outline_item(title, options, &block)
      outline_item = create_outline_item(title, options)
      prev.data.next = outline_item if prev
      parent.data.first = outline_item unless prev
      parent.data.last = outline_item
      increase_count
      self.prev = block ? nil : outline_item
      self.parent = outline_item if block
      yield if block
      return unless parent == outline_item

      self.prev = outline_item
      self.parent = outline_item.data.parent
    end

    def create_outline_item(title, options)
      outline_item = PDF::Core::OutlineItem.new(title, parent, options)
      case options[:destination]
      when Integer then outline_item.dest = [document.pages[options[:destination] - 1].dictionary, :Fit]
      when Array then outline_item.dest = options[:destination]
      end
      outline_item.prev = prev if @prev
      items[title] = document.ref!(outline_item)
    end

    def increase_count
      counting_parent = parent
      while counting_parent
        counting_parent.data.count += 1
        counting_parent = (counting_parent == root) ? nil : counting_parent.data.parent
      end
    end

    def insert_section(next_item)
      last = @parent.data.last
      yield if block_given?
      if next_item
        next_item.data.prev = @prev
        @prev.data.next = next_item
        @parent.data.last = last
      end
      @parent = root
      @prev = root.data.last
    end
  end
end

module PDF::Core
  module Destinations
    def dests
      names.data[:Dests] ||= ref!(PDF::Core::NameTree.new)
    end

    def add_dest(name, reference)
      reference = ref!(reference) unless reference.is_a?(PDF::Core::Reference)
      dests.data.add(name, reference)
    end

    def dest_xyz(left, top, zoom = nil, dest_page = page)
      [dest_page.dictionary, :XYZ, left, top, zoom]
    end

    def dest_fit(dest_page = page)
      [dest_page.dictionary, :Fit]
    end

    def dest_fit_horizontally(top, dest_page = page)
      [dest_page.dictionary, :FitH, top]
    end

    def dest_fit_vertically(left, dest_page = page)
      [dest_page.dictionary, :FitV, left]
    end

    def dest_fit_rect(left, bottom, right, top, dest_page = page)
      [dest_page.dictionary, :FitR, left, bottom, right, top]
    end

    def dest_fit_bounds(dest_page = page)
      [dest_page.dictionary, :FitB]
    end

    def dest_fit_bounds_horizontally(top, dest_page = page)
      [dest_page.dictionary, :FitBH, top]
    end

    def dest_fit_bounds_vertically(left, dest_page = page)
      [dest_page.dictionary, :FitBV, left]
    end
  end
end
