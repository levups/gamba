# frozen_string_literal: true

module Prawn
  module Errors
    PdfUaViolation = Class.new(StandardError)
  end
end

module Gamba
  # Tagged PDF (ISO 32000-1 §14.7 and §14.8), switched on with pdf: :ua (PDF/UA-1, ISO 14289-1) or pdf_a: :a
  # (PDF/A-3a): a structure tree that says what the content is and in which order it reads, each piece of content
  # drawn in a marked-content sequence naming its element, and what only decorates the page marked as an artifact.
  # Content drawn outside both raises: a reader would never see it.
  module Tagging
    # A node of the structure tree: a standard structure type (P, H1, Table…), its attributes (Alt, Lang, A), and
    # its kids, other elements or the marked-content sequences that hold its content, as [page, MCID].
    class Element
      attr_reader :type, :attributes, :kids

      def initialize(type, parent, attributes = {})
        @type = type
        @attributes = attributes
        @kids = []
        parent&.kids&.push(self)
      end

      # A figure is read as one: its alternative text, not what it is drawn with.
      def whole?
        @type == :Figure
      end

      # The table row of this table element at a row index of Prawn's table, made when its first cell is drawn.
      def row(index)
        (@rows ||= {})[index] ||= Element.new(:TR, self)
      end
    end

    # A marked-content sequence: around an element's content, or an artifact when element is nil. page is the page
    # it is open on, nil once a page break closed it there: it opens again on the next page, when something is drawn.
    Mark = Struct.new(:element, :properties, :page)

    # Operators starting what paints the page: a text object, a path, an image, a shading (ISO 32000-1 §8.2). A
    # marked-content sequence goes around them, never inside a text or a path object.
    BEGINS_GRAPHICS_OBJECT = /(?:\A|\s)(?:BT|BI|Do|m|re|sh)$/
    DOCUMENT_TYPE = :Document
    # A BCP 47 language tag, as /Lang takes it: fr, en-GB, zh-Hant-TW.
    LANGUAGE_TAG = /\A[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*\z/
    HEADING_LEVELS = {H1: 1, H2: 2, H3: 3, H4: 4, H5: 5, H6: 6}.freeze
    # Something besides spaces and invisible format characters (zero-width space, byte order mark…).
    VISIBLE = /[^[:space:]\p{Cf}]/

    # Text a reader sees or hears: a title, an alt. A string in another encoding counts if it converts to UTF-8,
    # and binary bytes if they are UTF-8, as File.binread returns them.
    def self.visible_text?(value)
      return false unless value.is_a?(String)

      value = value.dup.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::BINARY
      value.valid_encoding? && value.encode(Encoding::UTF_8).match?(VISIBLE)
    rescue EncodingError
      false
    end

    def tagged?
      !@tagging.nil?
    end

    def pdf_ua?
      @pdf_ua == true
    end

    # An element of the structure tree under the current one, which the block's elements and content go into.
    # Nothing is made untagged, or within an artifact.
    def tag_structure(type, **attributes, &)
      return yield unless tagging_structure? && !@tagging.last.whole?

      attributes.compact!
      check_text_attributes(type, attributes)
      check_list_nesting(type)
      check_heading_level(type) if pdf_ua?

      within_element(Tagging::Element.new(type, @tagging.last, attributes), &)
    end

    # A cell of the table element being drawn, in the row element of its row index: a header cell for a column,
    # or a data cell. In a figure, the cell is part of it; outside a table element, nothing is made.
    def tag_table_cell(row, header:, colspan:, rowspan:, &)
      return yield unless tagging_structure?
      return tag_content(&) if @tagging.last.whole?
      return yield unless (table = @tagging.last).type == :Table

      attributes = {}
      attributes[:Scope] = :Column if header
      attributes[:ColSpan] = colspan if colspan > 1
      attributes[:RowSpan] = rowspan if rowspan > 1
      cell = Tagging::Element.new(header ? :TH : :TD, table.row(row), attributes.empty? ? {} : {A: {O: :Table, **attributes}})
      within_element(cell) { within_mark(Tagging::Mark.new(cell), &) }
    end

    # What the block draws is the content of the current element.
    def tag_content(&)
      return yield unless tagging_structure?

      check_list_nesting(nil)
      within_mark(Tagging::Mark.new(@tagging.last), &)
    end

    # What the block draws only decorates the page, as a header or a footer of type :Pagination and subtype
    # :Header or :Footer: readers skip it. Elements and content within it are neither made nor marked.
    def tag_artifact(type = nil, subtype = nil, &)
      return yield unless tagged?

      properties = type && "<</Type /#{type}#{" /Subtype /#{subtype}" if subtype}>>"
      within_mark(Tagging::Mark.new(nil, properties), &)
    end

    # What only decorates a part of the content, a table cell's background or border: an artifact, unless it is
    # drawn within tagged content, a table nested in a cell, where an artifact cannot be (ISO 14289-1 §7.1).
    def tag_decoration(&)
      return yield if tagged? && @marks.any?(&:element)

      tag_artifact(&)
    end

    private

    def initialize_tagging(options)
      pdf = options.delete(:pdf)
      raise ArgumentError, "pdf is #{pdf.inspect}: :ua is the only conformance level, PDF/UA-1" unless [nil, false, :ua].include?(pdf)

      @pdf_ua = pdf == :ua
      return unless @pdf_ua || @pdf_a_conformance == "A"

      check_tagging_options(options)
      # The open elements, the document's own first, then the marks open on the page, the innermost last.
      @tagging = [Tagging::Element.new(DOCUMENT_TYPE, nil)]
      @marks = []
      # By page, the element of each marked-content sequence, at its MCID.
      @elements_by_page = {}.compare_by_identity
    end

    def check_tagging_options(options)
      lang = options[:lang]
      if lang && !(lang.is_a?(String) && lang.match?(Tagging::LANGUAGE_TAG))
        raise ArgumentError, "lang is #{lang.inspect}: give a language tag, \"fr\" or \"en-GB\""
      end
      return unless @pdf_ua

      unless lang
        raise Prawn::Errors::PdfUaViolation, 'PDF/UA documents say their language, for screen readers to speak it: lang: "en"'
      end
      title = options.dig(:info, :Title)
      return if Tagging.visible_text?(title)

      raise Prawn::Errors::PdfUaViolation, "PDF/UA documents have a title, shown in the window bar: info: {Title: \"…\"}, not #{title.inspect}"
    end

    def tagging_structure?
      tagged? && @marks.none? { _1.element.nil? }
    end

    # Boxes check their alt and lang when made (Gamba::Layout::Node): here a figure must have an alt.
    def check_text_attributes(type, attributes)
      alt = attributes[:Alt]
      if type == :Figure && !Tagging.visible_text?(alt)
        raise tagging_violation, "#{tagging_standard} gives every figure an alternative text: alt: \"…\", not #{alt.inspect}"
      end
    end

    # A list holds list items only, and a list item sits in a list. type is nil for content marked in the current
    # element.
    def check_list_nesting(type)
      parent = @tagging.last.type
      return unless (type == :LI) ? parent != :L : (parent == :L && type != :LI)

      raise tagging_violation, (type == :LI) ? "#{tagging_standard} puts a list item in a list: role: :list on its container" :
        "#{tagging_standard} puts only list items in a list: role: :list_item on each of its boxes"
    end

    # PDF/UA reads headings as an outline: the first is an h1, and each goes at most one level below the last.
    def check_heading_level(type)
      level = HEADING_LEVELS[type]
      return unless level

      last = @heading_level || 0
      if level > last + 1
        raise Prawn::Errors::PdfUaViolation, "PDF/UA does not skip heading levels: an h#{level} " \
          "#{last.zero? ? "comes first, before any h1" : "follows an h#{last}"}"
      end
      @heading_level = level
    end

    def tagging_standard
      pdf_ua? ? "PDF/UA" : "PDF/A-3a"
    end

    def tagging_violation
      pdf_ua? ? Prawn::Errors::PdfUaViolation : Prawn::Errors::PdfAViolation
    end

    def within_element(element)
      @tagging << element
      yield
    ensure
      @tagging.pop
    end

    # The sequence is written when something is drawn in it: a box that moves to the next page before drawing
    # leaves no empty sequence behind, and its decoration sees nothing drawn on the page it leaves.
    def within_mark(mark)
      @marks << mark
      begin
        yield
      ensure
        @marks.pop
        add_content("EMC") if mark.page
      end
    end

    def write_mark(mark)
      mark.page = page
      if mark.element
        elements = (@elements_by_page[page] ||= [])
        mark.element.kids << [page, elements.size]
        add_content("/#{mark.element.type} <</MCID #{elements.size}>> BDC")
        elements << mark.element
      else
        add_content(mark.properties ? "/Artifact #{mark.properties} BDC" : "/Artifact BMC")
      end
    end

    # Called before the content goes to the page: what paints opens the sequences not written on this page yet, or
    # raises when it is in none. Within an artifact, only the outermost one is: what it holds is part of it, and
    # the elements around it wait for content of their own.
    def check_tagged_content(string)
      innermost = @marks.last
      return if innermost&.page || !string.match?(Tagging::BEGINS_GRAPHICS_OBJECT)

      unless innermost
        raise tagging_violation, "#{tagging_standard} tags all content, and this is drawn outside any tagged box or artifact: " \
          "draw it with Gamba's boxes, or leave it out (#{string.strip.lines.last.strip.inspect})"
      end

      artifact = @marks.index { _1.element.nil? }
      if artifact
        # Artifacts within one, a decoration moved beneath what it holds, are written too: they leave it.
        @marks[artifact..].each { |mark| write_mark(mark) unless mark.element || mark.page }
      else
        @marks.each { |mark| write_mark(mark) unless mark.page }
      end
    end

    # Before leaving a page, the sequences open on it are closed there.
    def close_marks_on_page
      @marks&.reverse_each do |mark|
        next unless mark.page

        add_content("EMC")
        mark.page = nil
      end
    end

    # The structure tree, the parent tree that maps each page's marked content back to its elements, and the
    # catalog entries a tagged PDF and PDF/UA ask for.
    def finalize_tagging
      raise ArgumentError, "a marked-content sequence is still open" unless @marks.empty?

      min_version(1.7)
      references = {}.compare_by_identity
      tree = ref!(Type: :StructTreeRoot)
      tree.data[:K] = [structure_reference(@tagging.first, tree, references)]
      nums = []
      pages.each do |page|
        elements = @elements_by_page[page]
        next unless elements

        page.dictionary.data[:StructParents] = nums.size / 2
        nums << (nums.size / 2) << elements.map { references.fetch(_1) }
      end
      tree.data[:ParentTree] = ref!(Nums: nums)
      tree.data[:ParentTreeNextKey] = nums.size / 2
      @root.data[:StructTreeRoot] = tree
      @root.data[:MarkInfo] = {Marked: true}
      @root.data[:ViewerPreferences] = {**(@root.data[:ViewerPreferences] || {}), DisplayDocTitle: true}
    end

    def structure_reference(element, parent, references)
      reference = ref!(Type: :StructElem, S: element.type, P: parent, **element.attributes)
      references[element] = reference
      reference.data[:K] = element.kids.map do |kid|
        next structure_reference(kid, reference, references) if kid.is_a?(Tagging::Element)

        page, mcid = kid
        {Type: :MCR, Pg: page.dictionary, MCID: mcid}
      end
      reference
    end
  end
end
