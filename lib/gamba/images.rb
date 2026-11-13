# frozen_string_literal: true

require "digest/sha1"
require "pathname"

module Prawn
  def self.image_handler
    @image_handler ||= ImageHandler.new
  end

  # The image formats Gamba knows, tried in order on an image's first bytes.
  class ImageHandler
    def initialize
      @handlers = []
    end

    def register(handler)
      @handlers.delete(handler)
      @handlers.push(handler)
    end

    def register!(handler)
      @handlers.delete(handler)
      @handlers.unshift(handler)
    end

    def unregister(handler)
      @handlers.delete(handler)
    end

    def find(image_blob)
      @handlers.find { _1.can_render?(image_blob) } || raise(Errors::UnsupportedImageType, "image file is an unrecognised format")
    end
  end

  module Images
    def image(file, options = {})
      Prawn.verify_options(%i[at position vposition height width scale fit], options)
      pdf_object, info = build_image_object(file)
      embed_image(pdf_object, info, options)
      info
    end

    # The same image bytes are embedded once per document, however many times they are placed.
    def build_image_object(file)
      image_content = verify_and_read_image(file)
      entry = image_registry[Digest::SHA1.hexdigest(image_content)] ||= begin
        info = Prawn.image_handler.find(image_content).new(image_content)
        min_version(info.min_pdf_version) if info.respond_to?(:min_pdf_version)
        {obj: info.build_pdf_object(self), info:}
      end
      [entry[:obj], entry[:info]]
    end

    # A page of another PDF, placed and sized as an image is, written once however many times it is drawn: a
    # letterhead, a form to fill in. source: a path, an IO, or the bytes of a PDF; page: from 1.
    def pdf_page(source, options = {})
      options = options.dup
      number = options.delete(:page) || 1
      Prawn.verify_options(%i[at position vposition height width scale fit], options)
      pdf_object, info = build_pdf_page_object(source, number)
      embed_image(pdf_object, info, options)
      info
    end

    def build_pdf_page_object(source, number = 1)
      bytes = Gamba::ImportedPage.bytes(source)
      imported = (@imported_pdfs ||= {})[Digest::SHA1.hexdigest(bytes)] ||= {source: Gamba::ImportedPage.source(self, bytes), pages: {}}
      page = imported[:pages][number] ||= Gamba::ImportedPage.new(self, imported[:source], number)
      [page.form, page]
    end

    def embed_image(pdf_object, info, options)
      width, height = info.calc_image_dimensions(options)
      if options[:at]
        x, y = map_to_absolute(options[:at])
      else
        x, y = image_position(width, height, options)
        move_text_position(height)
      end
      label = "I#{@image_counter = (@image_counter || 0) + 1}"
      page.xobjects[label] = pdf_object
      matrix = info.respond_to?(:placement) ? info.placement(width, height, x, y - height) : [width, 0, 0, height, x, y - height]
      add_content("\nq\n#{PDF::Core.real_params(matrix)} cm\n/#{label} Do\nQ")
    end

    private

    # An IO, a path, or anything answering download, as Active Storage attachments and blobs do.
    def verify_and_read_image(io_or_path)
      return io_or_path.download if io_or_path.respond_to?(:download) && !io_or_path.respond_to?(:rewind)

      if io_or_path.respond_to?(:rewind)
        io_or_path.rewind
        io_or_path.binmode if io_or_path.respond_to?(:binmode)
        return io_or_path.read
      end
      path = Pathname.new(io_or_path)
      raise ArgumentError, "#{path} not found" unless path.file?

      path.binread
    end

    def image_position(width, height, options)
      options[:position] ||= :left
      y =
        case options[:vposition]
        when :top then bounds.absolute_top
        when :center then bounds.absolute_top - ((bounds.height - height) / 2.0)
        when :bottom then bounds.absolute_bottom + height
        when Numeric then bounds.absolute_top - options[:vposition]
        else determine_y_with_page_flow(height)
        end
      x =
        case options[:position]
        when :left then bounds.left_side
        when :center then bounds.left_side + ((bounds.width - width) / 2.0)
        when :right then bounds.right_side - width
        when Numeric then options[:position] + bounds.left_side
        end
      [x, y]
    end

    def determine_y_with_page_flow(height)
      bounds.move_past_bottom if overruns_page?(height)
      y
    end

    def overruns_page?(height)
      (y - height) < reference_bounds.absolute_bottom
    end

    def image_registry
      @image_registry ||= {}
    end
  end
end
