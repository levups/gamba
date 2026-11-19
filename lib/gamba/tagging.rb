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
    HEADING_LEVELS = {H1: 1, H2: 2, H3: 3, H4: 4, H5: 5, H6: 6}.freeze

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
      raise tagging_violation, "#{tagging_standard} gives every figure an alternative text: alt: \"…\"" if type == :Figure && !attributes[:Alt]
      check_heading_level(type) if pdf_ua?

      within_element(Tagging::Element.new(type, @tagging.last, attributes), &)
    end

    # A cell of the table element being drawn, in the row element of its row index: a header cell for a column,
    # or a data cell. Outside a table element, nothing is made.
    def tag_table_cell(row, header:, colspan:, rowspan:, &)
      table = @tagging&.last
      return yield unless tagging_structure? && table.type == :Table

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

      within_mark(Tagging::Mark.new(@tagging.last), &)
    end

    # What the block draws only decorates the page, as a header or a footer of type :Pagination and subtype
    # :Header or :Footer: readers skip it. Elements and content within it are neither made nor marked.
    def tag_artifact(type = nil, subtype = nil, &)
      return yield unless tagged?

      properties = type && "<</Type /#{type}#{" /Subtype /#{subtype}" if subtype}>>"
      within_mark(Tagging::Mark.new(nil, properties), &)
    end

    private

    def initialize_tagging(options)
      pdf = options.delete(:pdf)
      raise ArgumentError, "pdf is #{pdf.inspect}: :ua is the only conformance level, PDF/UA-1" unless pdf.nil? || pdf == :ua

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
      return unless @pdf_ua

      unless options[:lang]
        raise Prawn::Errors::PdfUaViolation, 'PDF/UA documents say their language, for screen readers to speak it: lang: "en"'
      end
      return if options.dig(:info, :Title)

      raise Prawn::Errors::PdfUaViolation, 'PDF/UA documents have a title, shown in the window bar: info: {Title: "…"}'
    end

    def tagging_structure?
      tagged? && @marks.none? { _1.element.nil? }
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

    def within_mark(mark)
      open_mark(mark)
      begin
        yield
      ensure
        @marks.pop
        add_content("EMC") if mark.page
      end
    end

    def open_mark(mark)
      @marks << mark
      write_mark(mark)
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

    # Called before the content goes to the page: what paints opens again the sequences a page break closed, or
    # raises when it is in none.
    def check_tagged_content(string)
      return unless string.match?(Tagging::BEGINS_GRAPHICS_OBJECT)

      if @marks.empty?
        raise tagging_violation, "#{tagging_standard} tags all content, and this is drawn outside any tagged box or artifact: " \
          "draw it with Gamba's boxes, or leave it out (#{string.strip.lines.last.strip.inspect})"
      end
      return if @marks.last.page

      @marks.each { |mark| write_mark(mark) unless mark.page }
    end

    # Before leaving a page, the sequences open on it are closed there.
    def close_marks_on_page
      return unless @marks&.any?(&:page)

      @marks.reverse_each do |mark|
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
