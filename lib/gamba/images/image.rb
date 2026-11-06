# frozen_string_literal: true

module Prawn
  module Images
    class Image
      attr_accessor :scaled_width, :scaled_height

      def calc_image_dimensions(options)
        w = options[:width] || width
        h = options[:height] || height
        if options[:width] && !options[:height]
          ratio = w / Float(width)
          w = width * ratio
          h = height * ratio
        elsif options[:height] && !options[:width]
          ratio = h / Float(height)
          w = width * ratio
          h = height * ratio
        elsif options[:scale]
          w = width * options[:scale]
          h = height * options[:scale]
        elsif options[:fit]
          box_width, box_height = options[:fit]
          if width / Float(height) > box_width / Float(box_height)
            w = box_width
            h = box_width / (width / Float(height))
          else
            h = box_height
            w = box_height * (width / Float(height))
          end
        end
        self.scaled_width = w
        self.scaled_height = h
        [w, h]
      end
    end

    class JPG < Image
      class FormatError < StandardError
      end

      START_OF_FRAME_MARKERS = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze
      MARKER_PREFIX = 0xFF
      COLOR_SPACE_BY_CHANNELS = {1 => :DeviceGray, 3 => :DeviceRGB, 4 => :DeviceCMYK}.freeze
      # Adobe's CMYK JPEGs store inverted values.
      INVERTED_CMYK_DECODE = [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0].freeze

      attr_reader :width, :height, :bits, :channels

      def self.can_render?(image_blob)
        image_blob.byteslice(0, 3).bytes == [255, 216, 255]
      end

      def initialize(data)
        super()
        @data = data
        position = 2
        loop do
          marker, code, length = data.byteslice(position, 4)&.unpack("CCn")
          raise FormatError, "JPEG marker not found!" if marker != MARKER_PREFIX
          raise FormatError, "Truncated JPEG" if length.nil?

          if START_OF_FRAME_MARKERS.include?(code)
            raise FormatError, "Truncated JPEG frame header" if position + 10 > data.bytesize

            @bits, @height, @width, @channels = data.unpack("@#{position + 4} CnnC")
            raise FormatError, "JPEG of #{@width}x#{@height} pixels at #{@bits} bits" unless @bits.positive? && @height.positive? && @width.positive?

            break
          end
          position += 2 + length
        end
      end

      def build_pdf_object(document)
        color_space = COLOR_SPACE_BY_CHANNELS.fetch(channels) { raise ArgumentError, "JPG uses an unsupported number of channels" }
        dictionary = {Type: :XObject, Subtype: :Image, ColorSpace: color_space, BitsPerComponent: bits, Width: width, Height: height, Filter: :DCTDecode}
        dictionary[:Decode] = INVERTED_CMYK_DECODE if color_space == :DeviceCMYK
        document.ref!(dictionary, @data)
      end
    end

    class PNG < Image
      SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].freeze
      GRAYSCALE = 0
      TRUE_COLOR = 2
      INDEXED = 3
      GRAYSCALE_ALPHA = 4
      TRUE_COLOR_ALPHA = 6
      PNG_PREDICTORS = 15
      # Compressed input fed at a time: at zlib's highest ratio, 4 KB inflate to about 4 MB before the size check.
      INFLATE_CHUNK_BYTES = 4096
      MAXIMUM_IMAGE_BYTES = 1 << 30
      # Pixels split at a time: the unpack layout and its integers stay a few kilobytes, whatever the width.
      ALPHA_SPLIT_CHUNK_PIXELS = 1024
      # The bit depths the PNG specification allows for each color type.
      BIT_DEPTHS = {GRAYSCALE => [1, 2, 4, 8, 16], TRUE_COLOR => [8, 16], INDEXED => [1, 2, 4, 8],
                    GRAYSCALE_ALPHA => [8, 16], TRUE_COLOR_ALPHA => [8, 16]}.freeze

      attr_reader :palette, :transparency, :width, :height, :bits, :color_type, :compression_method,
        :filter_method, :interlace_method, :alpha_channel

      def self.can_render?(image_blob)
        image_blob.byteslice(0, 8).bytes == SIGNATURE
      end

      def initialize(data)
        super()
        @palette = +"".b
        compressed = +"".b
        @transparency = {}
        position = 8
        loop do
          raise Errors::UnsupportedImageType, "Truncated PNG" if position + 8 > data.bytesize

          length, section = data.unpack("@#{position} N a4")
          raise Errors::UnsupportedImageType, "Truncated PNG #{section} chunk" if position + 8 + length > data.bytesize

          chunk = data.byteslice(position + 8, length)
          case section
          when "IHDR"
            @width, @height, @bits, @color_type, @compression_method, @filter_method, @interlace_method = chunk.unpack("NNCCCCC")
          when "PLTE" then @palette << chunk
          when "IDAT" then compressed << chunk
          when "tRNS"
            @transparency =
              case @color_type
              when INDEXED then {palette: chunk.unpack("C*")}
              # Shorter than the samples they need, they would write a /Mask of nulls: ignored, as viewers do.
              when GRAYSCALE then (chunk.bytesize >= 2) ? {grayscale: chunk.unpack1("n")} : {}
              when TRUE_COLOR then (chunk.bytesize >= 6) ? {rgb: chunk.unpack("nnn")} : {}
              else {}
              end
          when "IEND" then break
          end
          position += 12 + length
        end
        raise Errors::UnsupportedImageType, "PNG without a valid IHDR chunk" unless @width.to_i.positive? && @height.to_i.positive? && @bits.to_i.positive?

        @compressed_data = compressed
      end

      # Inflated up to the size the header announces, never more: a few kilobytes of crafted data could otherwise
      # inflate into gigabytes.
      def img_data
        @img_data ||= begin
          samples = (colors || 1) + ((alpha_channel? && color_type != INDEXED) ? 1 : 0)
          expected_bytes = height * (1 + (((width * bits * samples) + 7) / 8))
          raise Errors::UnsupportedImageType, "PNG of #{width}x#{height} pixels is too large" if expected_bytes > MAXIMUM_IMAGE_BYTES

          inflater = Zlib::Inflate.new
          inflated = +"".b
          (0...@compressed_data.bytesize).step(INFLATE_CHUNK_BYTES) do |offset|
            inflated << inflater.inflate(@compressed_data.byteslice(offset, INFLATE_CHUNK_BYTES))
            raise Errors::UnsupportedImageType, "PNG data inflates beyond its #{width}x#{height} size" if inflated.bytesize > expected_bytes
          end
          inflated << inflater.finish
          inflated
        rescue Zlib::Error => exception
          raise Errors::UnsupportedImageType, "Corrupt PNG data: #{exception.message}"
        ensure
          # A refused stream is still mid-inflate: closing it as is warns under -w.
          inflater&.reset
          inflater&.close
        end
      end

      def colors
        case color_type
        when GRAYSCALE, INDEXED, GRAYSCALE_ALPHA then 1
        when TRUE_COLOR, TRUE_COLOR_ALPHA then 3
        end
      end

      def alpha_channel?
        return true if color_type == GRAYSCALE_ALPHA || color_type == TRUE_COLOR_ALPHA
        return @transparency.any? if color_type == INDEXED

        false
      end

      def min_pdf_version
        if bits > 8 then 1.5
        elsif alpha_channel? then 1.4
        else 1.0
        end
      end

      def build_pdf_object(document)
        raise Errors::UnsupportedImageType, "PNG uses an unsupported compression method" if compression_method != 0
        raise Errors::UnsupportedImageType, "PNG uses an unsupported filter method" if filter_method != 0
        raise Errors::UnsupportedImageType, "PNG uses unsupported interlace method" if interlace_method != 0
        raise Errors::UnsupportedImageType, "PNG uses an invalid bit depth" if BIT_DEPTHS[color_type]&.include?(bits) == false
        raise Errors::UnsupportedImageType, "PNG has a palette of #{palette.bytesize / 3} colors" if color_type == INDEXED && !(3..768).cover?(palette.bytesize)

        dictionary = {Type: :XObject, Subtype: :Image, Height: height, Width: width, BitsPerComponent: bits}
        if color_type == INDEXED && alpha_channel?
          index_samples, alpha_samples = split_palette_transparency
          image = document.ref!(dictionary, index_samples)
          image.data[:SMask] = document.ref!(alpha_dictionary(8), alpha_samples)
        elsif alpha_channel?
          color_rows, alpha_rows = split_alpha_channel
          image = document.ref!(dictionary.merge(DecodeParms: predictors(colors)), color_rows)
          image.data[:SMask] = document.ref!(alpha_dictionary(bits).merge(DecodeParms: predictors(1)), alpha_rows)
        else
          image = document.ref!(dictionary.merge(DecodeParms: predictors(colors)), img_data)
        end
        image.data[:ColorSpace] = if palette.empty?
          (colors == 1) ? :DeviceGray : :DeviceRGB
        else
          [:Indexed, :DeviceRGB, (palette.bytesize / 3) - 1, document.ref!({}, palette)]
        end
        # Data too short for one row still makes an image XObject, which must be a stream: viewers pad it.
        image.empty_stream = true
        image.data[:SMask]&.empty_stream = true
        if transparency[:grayscale]
          image.data[:Mask] = [transparency[:grayscale]] * 2
        elsif transparency[:rgb]
          image.data[:Mask] = transparency[:rgb].flat_map { [_1, _1] }
        end
        image
      end

      private

      # The reader undoes the PNG filters itself; the stream gets compressed again when the document is written.
      def predictors(color_count)
        {Predictor: PNG_PREDICTORS, Colors: color_count, BitsPerComponent: bits, Columns: width}
      end

      def alpha_dictionary(bits_per_component)
        {Type: :XObject, Subtype: :Image, Height: height, Width: width, BitsPerComponent: bits_per_component, ColorSpace: :DeviceGray, Decode: [0, 1]}
      end

      # Color and alpha rows, each keeping its filter byte: PNG filters predict a byte from the same channel of
      # the neighbouring pixels, which stays at the same relative place once the channels are apart.
      def split_alpha_channel
        sample_bytes = bits / 8
        pixel_bytes = (colors + 1) * sample_bytes
        row_bytes = (width * pixel_bytes) + 1
        row_count = img_data.bytesize / row_bytes
        chunk_pixels = [width, ALPHA_SPLIT_CHUNK_PIXELS].min
        chunk_count, remainder_pixels = width.divmod(chunk_pixels)
        chunk_layouts = alpha_split_layouts(sample_bytes, chunk_pixels)
        remainder_layouts = alpha_split_layouts(sample_bytes, remainder_pixels)
        color = +"".b
        alpha = +"".b
        row_count.times do |row_index|
          start = row_index * row_bytes
          filter = img_data.getbyte(start)
          color << filter
          alpha << filter
          chunk_count.times { split_pixels(start + 1 + (_1 * chunk_pixels * pixel_bytes), chunk_layouts, color, alpha) }
          split_pixels(start + 1 + (chunk_count * chunk_pixels * pixel_bytes), remainder_layouts, color, alpha) if remainder_pixels.positive?
        end
        [color, alpha]
      end

      def alpha_split_layouts(sample_bytes, pixels)
        color_bytes = colors * sample_bytes
        ["C#{color_bytes}x#{sample_bytes}" * pixels, "x#{color_bytes}C#{sample_bytes}" * pixels]
      end

      def split_pixels(offset, (color_layout, alpha_layout), color, alpha)
        img_data.unpack(color_layout, offset:).pack("C*", buffer: color)
        img_data.unpack(alpha_layout, offset:).pack("C*", buffer: alpha)
      end

      # Palette indices and their opacity: indices only mean something once the rows are unfiltered. Each byte of
      # a row maps to the opacity of the 8 / bits pixels it packs, through a table of its 256 values.
      def split_palette_transparency
        rows = PngDecoder.unfilter(img_data, ((width * bits) + 7) / 8, 1)
        alpha_by_index = Array.new(256) { |index| transparency[:palette][index] || 0xFF }
        pixels_per_byte = 8 / bits
        mask = (1 << bits) - 1
        alpha_by_byte = Array.new(256) do |byte|
          indices = Array.new(pixels_per_byte) { |pixel| (byte >> (8 - (bits * (pixel + 1)))) & mask }
          [byte.chr, indices.map { alpha_by_index[_1] }.pack("C*")]
        end.to_h
        alpha = rows.map { |row| row.gsub(/./mn, alpha_by_byte).byteslice(0, width) }
        [rows.join, alpha.join]
      end
    end
  end
end
