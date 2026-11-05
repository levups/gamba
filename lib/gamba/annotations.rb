# frozen_string_literal: true

module PDF::Core
  module Annotations
    def annotate(options)
      options = options.merge(Type: :Annot)
      options[:F] ||= Gamba::PdfA::PRINT_FLAG if pdf_a?
      options[:Dest] = PDF::Core::LiteralString.new(options[:Dest]) if options[:Dest].is_a?(String)
      (page.dictionary.data[:Annots] ||= []) << ref!(options)
      options
    end

    def text_annotation(rect, contents, options = {})
      annotate(options.merge(Subtype: :Text, Rect: rect, Contents: contents))
    end

    def link_annotation(rect, options = {})
      annotate(options.merge(Subtype: :Link, Rect: rect))
    end
  end
end
