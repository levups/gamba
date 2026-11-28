# frozen_string_literal: true

module Gamba
  # A page of a PDF written elsewhere, drawn like an image: a form XObject showing what a viewer shows of it, its
  # crop box turned by its /Rotate. Placed many times, it is written once; pages of one file share their resources.
  class ImportedPage < Prawn::Images::Image
    include PageBoxes

    # A file read once per document, its objects copied into it as its pages are used.
    Source = Struct.new(:reader, :copier, :pages)
    # Fonts whose glyphs need no font file: their procedures are in the PDF.
    FONT_PROGRAMS = %i[FontFile FontFile2 FontFile3].freeze
    TYPE3 = PDF::Core::Name.new(value: "Type3")
    FORM = PDF::Core::Name.new(value: "Form")
    # What a content stream holds between operators, read as viewers read it: whitespace and comments, strings,
    # names, numbers and delimiters; anything else is an operator. An inline image's data, from ID to EI, is binary.
    SKIPPED = /(?:[\x00\t\n\f\r ]+|%[^\r\n]*)+/n
    DELIMITER_OR_NUMBER = %r{<<|>>|[\[\]{}]|<[^>]*>|[+-]?(?:\d+\.?\d*|\.\d+)}n
    NAME = %r{/([^\x00\t\n\f\r ()<>\[\]{}/%]*)}n
    OPERATOR = %r{[^\x00\t\n\f\r ()<>\[\]{}/%]+}n
    INLINE_IMAGE_DATA = /.*?[\x00\t\n\f\r ]EI(?=[\x00\t\n\f\r ]|\z)/mn
    # Operands that are not operators, though spelled as keywords.
    CONSTANTS = %w[true false null].freeze
    # Optional content marks a layer, not structure: /OC /Layer1 BDC is allowed in a figure.
    OPTIONAL_CONTENT = "OC"
    MARKED_CONTENT_OPERATORS = %w[BDC BMC].freeze

    attr_reader :width, :height, :form

    # source: a path, an IO, the bytes of a PDF, or anything answering download, as Active Storage attachments do.
    def self.bytes(source)
      if source.respond_to?(:download) && !source.respond_to?(:read)
        source.download.b
      elsif source.respond_to?(:read)
        source.rewind if source.respond_to?(:rewind)
        source.read.b
      elsif source.is_a?(String) && source.b.start_with?("%PDF-")
        source.b
      else
        path = Pathname.new(source)
        raise ArgumentError, "#{path} not found" unless path.file?

        path.binread
      end
    end

    def self.source(document, bytes)
      reader = PDF::Core::Reader.new(bytes)
      document.min_version(reader.version)
      Source.new(reader, Copier.new(reader) { document.ref!(_1) }, reader.pages)
    end

    def initialize(document, source, number)
      super()
      @reader = source.reader
      raise Prawn::Errors::MalformedPDF, "This PDF has no pages" if source.pages.empty?
      unless number.is_a?(Integer) && number.between?(1, source.pages.size)
        raise ArgumentError, "page is #{number.inspect}: this PDF has pages 1 to #{source.pages.size}"
      end

      page = source.pages[number - 1].last
      if document.pdf_a? || document.pdf_ua?
        # PDF/A and PDF/UA both embed every font; PDF/UA names the error when both apply, as everywhere else.
        @embedding_violation = document.pdf_ua? ? [Prawn::Errors::PdfUaViolation, "PDF/UA"] : [Prawn::Errors::PdfAViolation, "PDF/A"]
        check_fonts_embedded(page[:Resources], {})
      end
      @decoded = {}.compare_by_identity
      check_no_marked_content(page, document) if document.tagged?
      @form = document.ref!(form_dictionary(page, source.copier))
      @form.stream, filters = content(page[:Contents], source.copier)
      @form.data.merge!(filters)
      source.copier.finish
    end

    # What draws the page in a box of this width and height, from its lower left corner.
    def placement(width, height, x, y)
      [width / @width.to_f, 0, 0, height / @height.to_f, x, y]
    end

    private

    # The form maps the visible box, turned, onto a box from the origin as wide and high as the page is shown.
    def form_dictionary(page, copier)
      left, bottom, right, top = visible_box(page)
      width = right - left
      height = top - bottom
      turn = rotation(page)
      @width, @height = (turn % 180).zero? ? [width, height] : [height, width]
      matrix = [1.0, 0.0, 0.0, 1.0, -left, -bottom]
      matrix = multiply(matrix, ROTATIONS.fetch(turn).call(width, height)) unless turn.zero?
      dictionary = {Type: :XObject, Subtype: :Form, BBox: [left, bottom, right, top], Matrix: matrix, Resources: copier.copy(page[:Resources] || {})}
      dictionary[:Group] = copier.copy(page[:Group]) if page[:Group]
      dictionary
    end

    # A form holds one stream: a page's only content stream keeps its bytes and filters, several are decoded and
    # joined, as their division may fall between an operator and its operands.
    def content(value, copier)
      streams = content_streams(value)
      return [+" ", {}] if streams.empty?
      return [+streams.first.data, copier.copy(streams.first.dictionary.slice(:Filter, :DecodeParms))] if streams.one?

      [streams.map { decoded(_1) }.join("\n"), {}]
    end

    # The page is drawn as one figure or artifact: marked content of its own, in its content streams or in the forms
    # they draw, would nest in it, which tagged PDF forbids, and its MCIDs would point at a structure tree left
    # behind. Optional content (/OC … BDC) only marks a layer, and is drawn as is.
    def check_no_marked_content(page, document)
      return unless content_streams(page[:Contents]).any? { marked_content?(decoded(_1)) } || forms_mark_content?(page[:Resources], {})

      error, standard = document.pdf_ua? ? [Prawn::Errors::PdfUaViolation, "PDF/UA"] : [Prawn::Errors::PdfAViolation, "PDF/A-3a"]
      raise error, "#{standard} cannot import a page that has marked content of its own, a page of a tagged PDF: Gamba does not merge structure trees yet"
    end

    def forms_mark_content?(resources, visited)
      xobjects = @reader.resolve(@reader.resolve(resources).then { _1.is_a?(Hash) ? _1[:XObject] : nil })
      return false unless xobjects.is_a?(Hash)

      xobjects.each_value.any? do |reference|
        next false if !reference.is_a?(PDF::Core::Reader::Ref) || visited[reference.number]

        visited[reference.number] = true
        form = @reader.resolve(reference)
        next false unless form.is_a?(PDF::Core::Reader::Stream) && form.dictionary[:Subtype] == FORM

        marked_content?(decoded(form)) || forms_mark_content?(form.dictionary[:Resources], visited)
      end
    end

    # Whether a content stream has a BDC or BMC operator other than optional content's, its tag being the first name
    # among its operands; strings, comments and inline images, which may spell them too, are skipped.
    def marked_content?(data)
      scanner = StringScanner.new(data)
      tag = nil
      until scanner.eos?
        next if scanner.skip(SKIPPED) || scanner.skip(DELIMITER_OR_NUMBER)

        if scanner.match?(/\(/n)
          skip_literal_string(scanner)
        elsif scanner.skip(NAME)
          tag ||= scanner[1]
        elsif (operator = scanner.scan(OPERATOR))
          next if CONSTANTS.include?(operator)
          return true if MARKED_CONTENT_OPERATORS.include?(operator) && tag != OPTIONAL_CONTENT

          scanner.skip(INLINE_IMAGE_DATA) || scanner.terminate if operator == "ID"
          tag = nil
        else
          scanner.getch # a stray ) or >
        end
      end
      false
    end

    def skip_literal_string(scanner)
      depth = 0
      until scanner.eos?
        scanner.skip(/[^\\()]*/n)
        case scanner.getch
        when "(" then depth += 1
        when ")" then return if (depth -= 1).zero?
        when "\\" then scanner.getch
        end
      end
    end

    def content_streams(contents)
      Array(@reader.resolve(contents)).map { @reader.resolve(_1) }.grep(PDF::Core::Reader::Stream)
    end

    # Each stream is decoded once, though both the check and the form read a page's several streams.
    def decoded(stream)
      @decoded[stream] ||= @reader.decoded(stream)
    end

    # PDF/A wants every font's program in the file: a page that leaves one to the viewer raises.
    def check_fonts_embedded(resources, visited)
      resources = @reader.resolve(resources)
      return unless resources.is_a?(Hash)

      fonts = @reader.resolve(resources[:Font])
      fonts.each_value { |font| check_font_embedded(@reader.resolve(font)) } if fonts.is_a?(Hash)
      xobjects = @reader.resolve(resources[:XObject])
      return unless xobjects.is_a?(Hash)

      xobjects.each_value do |reference|
        next if !reference.is_a?(PDF::Core::Reader::Ref) || visited[reference.number]

        visited[reference.number] = true
        xobject = @reader.resolve(reference)
        check_fonts_embedded(xobject.dictionary[:Resources], visited) if xobject.is_a?(PDF::Core::Reader::Stream) && xobject.dictionary[:Subtype] == FORM
      end
    end

    def check_font_embedded(font)
      return unless font.is_a?(Hash) && font[:Subtype] != TYPE3

      descendant = @reader.resolve(@reader.resolve(font[:DescendantFonts]).then { _1.is_a?(Array) ? _1.first : nil })
      font = descendant if descendant.is_a?(Hash)
      descriptor = @reader.resolve(font[:FontDescriptor])
      return if descriptor.is_a?(Hash) && FONT_PROGRAMS.any? { descriptor[_1] }

      name = @reader.resolve(font[:BaseFont])
      error, standard = @embedding_violation
      raise error, "#{standard} embeds every font: the page uses #{name.respond_to?(:value) ? name.value : "a font"} without its font file"
    end
  end
end
