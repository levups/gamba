# frozen_string_literal: true

require "strscan"
require "zlib"

module PDF
  module Core
    # Reads a PDF written by someone else, versions 1.0 to 1.7 and 2.0: xref tables and cross-reference streams,
    # object streams, incremental updates (ISO 32000-1 §7.5). Objects are parsed when first asked for. When the
    # cross-reference data is missing or points to the wrong bytes, the reader rebuilds it by scanning the file, as
    # viewers do. Streams keep their encoded bytes: only object and cross-reference streams are decoded.
    class Reader
      Ref = Data.define(:number, :generation)
      Stream = Data.define(:dictionary, :data)

      WHITESPACE = /(?:[\x00\t\n\f\r ]+|%[^\r\n]*)*/n
      NAME_BODY = %r{[^\x00\t\n\f\r ()<>\[\]{}/%]*}n
      NUMBER = /[+-]?(?:\d+\.?\d*|\.\d+)/n
      REFERENCE_TAIL = /[\x00\t\n\f\r ]+(\d+)[\x00\t\n\f\r ]+R(?![^\x00\t\n\f\r ()<>\[\]{}\/%])/n
      OBJECT_HEADER = /[\x00\t\n\f\r ]*(\d+)[\x00\t\n\f\r ]+(\d+)[\x00\t\n\f\r ]+obj/n
      OBJECT_HEADER_ANYWHERE = /(?<![0-9])(\d+)[\x00\t\n\f\r ]+(\d+)[\x00\t\n\f\r ]+obj(?![^\x00\t\n\f\r ()<>\[\]{}\/%])/n
      STREAM_KEYWORD = /stream(?:\r\n|\n|\r)?/n
      KEYWORD = /[^\x00\t\n\f\r ()<>\[\]{}\/%]+/n
      LITERAL_ESCAPES = {"n" => "\n", "r" => "\r", "t" => "\t", "b" => "\b", "f" => "\f"}.freeze
      INHERITED_PAGE_KEYS = %i[Resources MediaBox CropBox Rotate].freeze
      TYPE_PAGES = Name.new(value: "Pages")
      TYPE_OBJECT_STREAM = Name.new(value: "ObjStm")
      FLATE = Name.new(value: "FlateDecode")
      TYPE_CATALOG = Name.new(value: "Catalog")

      attr_reader :version

      def initialize(bytes)
        @bytes = bytes.b
        @scanner = StringScanner.new(@bytes)
        @objects = {}
        @object_streams = {}
        raise Prawn::Errors::MalformedPDF, "Not a PDF file: no %PDF- header" unless (header = @bytes.index("%PDF-")) && header < 1024

        @version = @bytes.byteslice(header + 5, 3).to_f
        begin
          read_cross_references
          raise Prawn::Errors::MalformedPDF, "The trailer has no /Root" unless @trailer[:Root]
        rescue Prawn::Errors::MalformedPDF
          rebuild_cross_references
        end
        decrypt_from_now_on if @trailer[:Encrypt] && !@decryption
        catalog_version = resolve(catalog[:Version])
        @version = [@version, catalog_version.value.to_f].max if catalog_version.is_a?(Name)
      end

      # A count or a size read from the file: anything but an integer reads as the default.
      def self.integer(value, default = 0)
        value.is_a?(Integer) ? value : default
      end

      def catalog
        catalog = resolve(@trailer[:Root])
        catalog.is_a?(Hash) ? catalog : {}
      end

      def resolve(value)
        value.is_a?(Ref) ? object(value.number) : value
      end

      def object(number)
        return @objects[number] if @objects.key?(number)

        @objects[number] = nil # a reference loop resolves to null instead of recursing forever
        @objects[number] = load_object(number)
      end

      # Each page with the attributes it inherits from its ancestors (ISO 32000-1 §7.7.3.4): [reference, dictionary].
      def pages
        pages = []
        visited = {}
        pending = [[catalog[:Pages], {}]]
        until pending.empty?
          reference, inherited = pending.pop
          if reference.is_a?(Ref)
            next if visited[reference.number]

            visited[reference.number] = true
          end
          node = resolve(reference)
          next unless node.is_a?(Hash)

          kids = resolve(node[:Kids])
          if node[:Type] == TYPE_PAGES || (node[:Type].nil? && kids.is_a?(Array))
            inherited = inherited.merge(node.slice(*INHERITED_PAGE_KEYS))
            Array(kids).reverse_each { pending << [it, inherited] }
          else
            pages << [reference, inherited.merge(node)]
          end
        end
        pages
      end

      private

      # Objects read so far were read as stored: forget them, so they are read again and decrypted.
      def decrypt_from_now_on
        encryption = resolve(@trailer[:Encrypt])
        raise Prawn::Errors::MalformedPDF, "The /Encrypt entry is not a dictionary" unless encryption.is_a?(Hash)

        @decryption = Decryption.new(encryption, Array(resolve(@trailer[:ID])).first.to_s.b,
          (@trailer[:Encrypt].number if @trailer[:Encrypt].is_a?(Ref)))
        @objects.clear
        @object_streams.clear
      end

      # The last startxref points to the newest section; each section's /Prev to the one it updates.
      def read_cross_references
        @locations = {}
        startxref = @bytes.rindex("startxref", -1) || raise(Prawn::Errors::MalformedPDF, "No startxref")
        @scanner.pos = startxref + 9
        skip_whitespace
        offset = @scanner.scan(/\d+/n)&.to_i || raise(Prawn::Errors::MalformedPDF, "No offset after startxref")
        visited = {}
        until offset.nil? || visited[offset]
          visited[offset] = true
          section_trailer = read_cross_reference_section(offset)
          @trailer ||= section_trailer
          read_cross_reference_section(section_trailer[:XRefStm]) if section_trailer[:XRefStm].is_a?(Integer)
          offset = section_trailer[:Prev].is_a?(Integer) ? section_trailer[:Prev] : nil
        end
      end

      def read_cross_reference_section(offset)
        raise Prawn::Errors::MalformedPDF, "startxref points outside the file" unless offset.between?(0, @bytes.bytesize - 1)

        @scanner.pos = offset
        skip_whitespace
        return read_cross_reference_table if @scanner.skip(/xref/n)

        number, _, value = parse_indirect_object_at(@scanner.pos)
        raise Prawn::Errors::MalformedPDF, "startxref points to neither a table nor a stream" unless value.is_a?(Stream)

        read_cross_reference_stream(number, value)
      end

      def read_cross_reference_table
        loop do
          skip_whitespace
          break unless (first = @scanner.scan(/\d+/n))

          skip_whitespace
          count = @scanner.scan(/\d+/n).to_i
          first = first.to_i
          count.times do |index|
            skip_whitespace
            @scanner.skip(/(\d+) +(\d+) +([nf])/n) || raise(Prawn::Errors::MalformedPDF, "Truncated xref table")
            # A subsection starting at 1 whose first entry is the free head of the list: the writer meant 0.
            first -= 1 if index.zero? && first == 1 && @scanner[1].to_i.zero? && @scanner[2] == "65535"
            next unless @scanner[3] == "n"

            @locations[first + index] ||= [:offset, @scanner[1].to_i]
          end
        end
        skip_whitespace
        raise Prawn::Errors::MalformedPDF, "No trailer after the xref table" unless @scanner.skip(/trailer/n)

        dictionary = parse_value
        raise Prawn::Errors::MalformedPDF, "The trailer is not a dictionary" unless dictionary.is_a?(Hash)

        dictionary
      end

      # Rows of /W widths: type (default 1), then offset or object stream, then generation or index (§7.5.8.3).
      def read_cross_reference_stream(stream_number, stream)
        dictionary = stream.dictionary
        widths = Array(dictionary[:W]).map { Reader.integer(it, -1) }
        raise Prawn::Errors::MalformedPDF, "Bad /W in a cross-reference stream" unless widths.size == 3 && widths.all? { it.between?(0, 8) }

        rows = decode(stream)
        row_width = widths.sum
        index = Array(dictionary[:Index] || [0, Reader.integer(dictionary[:Size])]).each_slice(2)
        position = 0
        index.each do |first, count|
          Reader.integer(count).times do |offset|
            break if position + row_width > rows.bytesize

            type = widths[0].zero? ? 1 : field(rows, position, widths[0])
            second = field(rows, position + widths[0], widths[1])
            third = field(rows, position + widths[0] + widths[1], widths[2])
            position += row_width
            number = Reader.integer(first) + offset
            next if @locations.key?(number)

            case type
            when 1 then @locations[number] = [:offset, second]
            when 2 then @locations[number] = [:compressed, second, third]
            end
          end
        end
        @locations[stream_number] ||= [:offset, nil]
        dictionary
      end

      def field(bytes, position, width)
        value = 0
        width.times { value = (value << 8) | bytes.getbyte(position + it) }
        value
      end

      # Every "N G obj" in the file, the last one winning as in an incremental update; then the objects packed in
      # object streams, and the trailer from the last trailer dictionary or cross-reference stream holding a /Root.
      def rebuild_cross_references
        @rebuilt = true
        @locations = {}
        @objects.clear
        @object_streams.clear
        @trailer = {}
        position = 0
        while (match = OBJECT_HEADER_ANYWHERE.match(@bytes, position))
          @locations[match[1].to_i] = [:offset, match.begin(0)]
          position = match.end(0)
        end
        position = 0
        while (start = @bytes.index("trailer", position))
          @scanner.pos = start + 7
          dictionary = begin
            parse_value
          rescue Prawn::Errors::MalformedPDF
            nil
          end
          @trailer.merge!(dictionary) if dictionary.is_a?(Hash)
          position = start + 7
        end
        @locations.keys.each do |number|
          value = object(number)
          @trailer.merge!(value.dictionary.slice(:Root, :Info, :ID, :Encrypt)) if value.is_a?(Stream) && value.dictionary[:Root]
        end
        # Object streams are encrypted as a whole: they can only be opened once the key is known.
        decrypt_from_now_on if @trailer[:Encrypt] && !@decryption
        @locations.keys.each do |number|
          value = object(number)
          next unless value.is_a?(Stream) && value.dictionary[:Type] == TYPE_OBJECT_STREAM

          offsets = begin
            object_stream(number)[2]
          rescue Prawn::Errors::MalformedPDF
            next # a damaged object stream loses its own objects, not the file
          end
          offsets.each_with_index { |(packed, _), index| @locations[packed] ||= [:compressed, number, index] }
        end
        @trailer[:Root] ||= @locations.keys.find { (catalog = object(it)).is_a?(Hash) && catalog[:Type] == TYPE_CATALOG }&.then { Ref.new(number: it, generation: 0) }
        raise Prawn::Errors::MalformedPDF, "No document catalog found" unless @trailer[:Root]
      end

      def load_object(number)
        type, field, index = @locations[number]
        case type
        when :offset
          return nil if field.nil?

          found, generation, value = parse_indirect_object_at(field)
          return @decryption ? @decryption.decrypt(value, number, generation) : value if found == number
          return nil if @rebuilt

          rebuild_cross_references
          object(number)
        when :compressed
          object_from_stream(field, index, number)
        end
      rescue Prawn::Errors::MalformedPDF
        nil
      end

      def parse_indirect_object_at(offset)
        raise Prawn::Errors::MalformedPDF, "Offset #{offset} is outside the file" unless offset.between?(0, @bytes.bytesize)

        @scanner.pos = offset
        raise Prawn::Errors::MalformedPDF, "No object at offset #{offset}" unless @scanner.skip(OBJECT_HEADER)

        number = @scanner[1].to_i
        generation = @scanner[2].to_i
        value = parse_value
        skip_whitespace
        value = Stream.new(dictionary: value, data: stream_data(value)) if value.is_a?(Hash) && @scanner.skip(STREAM_KEYWORD)
        [number, generation, value]
      end

      # /Length is trusted when "endstream" follows it; otherwise the data runs to the next "endstream".
      def stream_data(dictionary)
        start = @scanner.pos
        length = dictionary[:Length]
        length = load_length(length) if length.is_a?(Ref)
        if length.is_a?(Integer) && length >= 0 && start + length <= @bytes.bytesize
          @scanner.pos = start + length
          skip_whitespace
          return @bytes.byteslice(start, length) if @scanner.match?(/endstream/n)
        end
        finish = @bytes.index("endstream", start) || @bytes.bytesize
        finish -= 1 if finish > start && @bytes.getbyte(finish - 1) == 10
        finish -= 1 if finish > start && @bytes.getbyte(finish - 1) == 13
        @bytes.byteslice(start, finish - start)
      end

      def load_length(reference)
        saved = @scanner.pos
        object(reference.number)
      ensure
        @scanner.pos = saved
      end

      def object_from_stream(stream_number, index, number)
        stream = object_stream(stream_number)
        return nil unless stream

        data, first, offsets = stream
        found, offset = offsets[index]
        found, offset = offsets.find { it[0] == number } unless found == number
        return nil unless found && offset && (first + offset).between?(0, data.bytesize)

        scanner = @scanner
        @scanner = StringScanner.new(data)
        @scanner.pos = first + offset
        parse_value
      ensure
        @scanner = scanner if scanner
      end

      # [decoded bytes, /First, [[number, offset], ...]], inflated once per object stream; false when it is not a stream.
      def object_stream(stream_number)
        @object_streams[stream_number] ||= begin
          value = object(stream_number)
          if value.is_a?(Stream)
            data = decode(value)
            first = Reader.integer(value.dictionary[:First])
            [data, first, data.byteslice(0, first).to_s.scan(/\d+/n).map(&:to_i).each_slice(2).to_a]
          else
            false
          end
        end
      end

      # Object and cross-reference streams only: Flate, optionally with a PNG predictor (§7.4.4.4).
      def decode(stream)
        filters = [resolve(stream.dictionary[:Filter])].flatten
        filters.compact!
        parameters = [resolve(stream.dictionary[:DecodeParms])].flatten
        filters.each_with_index.reduce(stream.data) do |data, (filter, position)|
          raise Prawn::Errors::MalformedPDF, "Unsupported filter #{filter.inspect} on an object stream" unless filter == FLATE

          unpredict(inflate(data), resolve(parameters[position]))
        end
      end

      def inflate(data)
        zstream = Zlib::Inflate.new
        output = zstream.inflate(data)
        zstream.finish
        output
      rescue Zlib::Error => error
        partial_inflate(data) || raise(Prawn::Errors::MalformedPDF, "Corrupt object stream: #{error.message}")
      ensure
        zstream&.reset # closing an unfinished stream warns otherwise
        zstream&.close
      end

      # Truncated or padded streams: keep what inflates before the damage.
      def partial_inflate(data)
        zstream = Zlib::Inflate.new
        output = +"".b
        0.step(data.bytesize - 1, 1024) do |start|
          output << zstream.inflate(data.byteslice(start, 1024))
        rescue Zlib::Error
          break
        end
        output.empty? ? nil : output
      ensure
        zstream&.reset
        zstream&.close
      end

      def unpredict(data, parameters)
        return data if data.empty? || !parameters.is_a?(Hash) || Reader.integer(parameters[:Predictor]) < 10

        colors = Reader.integer(parameters[:Colors], 1).clamp(1, 32)
        bits = Reader.integer(parameters[:BitsPerComponent], 8).clamp(1, 16)
        columns = Reader.integer(parameters[:Columns], 1).clamp(1, data.bytesize)
        pixel_width = [(colors * bits + 7) / 8, 1].max
        row_width = (colors * bits * columns + 7) / 8
        output = +"".b
        previous = Array.new(row_width, 0)
        position = 0
        while position + 1 + row_width <= data.bytesize
          filter = data.getbyte(position)
          row = data.byteslice(position + 1, row_width).bytes
          row_width.times do |index|
            left = (index >= pixel_width) ? row[index - pixel_width] : 0
            up = previous[index]
            up_left = (index >= pixel_width) ? previous[index - pixel_width] : 0
            predicted = case filter
            when 1 then left
            when 2 then up
            when 3 then (left + up) / 2
            when 4 then paeth(left, up, up_left)
            else 0
            end
            row[index] = (row[index] + predicted) & 0xFF
          end
          output << row.pack("C*")
          previous = row
          position += 1 + row_width
        end
        output
      end

      def paeth(left, up, up_left)
        estimate = left + up - up_left
        distances = [(estimate - left).abs, (estimate - up).abs, (estimate - up_left).abs]
        return left if distances[0] <= distances[1] && distances[0] <= distances[2]

        (distances[1] <= distances[2]) ? up : up_left
      end

      def skip_whitespace
        @scanner.skip(WHITESPACE)
      end

      def parse_value
        skip_whitespace
        case @scanner.peek_byte
        when 47 then Name.new(value: name_bytes)
        when 40 then parse_literal_string
        when 60
          @scanner.match?(/<</n) ? parse_dictionary : parse_hex_string
        when 91 then parse_array
        when 43, 45, 46, 48..57 then parse_number
        when nil then raise Prawn::Errors::MalformedPDF, "Unexpected end of data"
        else parse_keyword
        end
      end

      def name_bytes
        @scanner.pos += 1 # the slash, which the callers have seen
        name = @scanner.scan(NAME_BODY)
        name.include?("#") ? name.gsub(/#(\h\h)/n) { it[1, 2].hex.chr } : name
      end

      def parse_number
        token = @scanner.scan(NUMBER) || raise(Prawn::Errors::MalformedPDF, "Bad number at #{@scanner.pos}")
        return Real.new(source: token) if token.include?(".")

        integer = token.to_i
        return Ref.new(number: integer, generation: @scanner[1].to_i) if !token.start_with?("+", "-") && @scanner.skip(REFERENCE_TAIL)

        integer
      end

      def parse_keyword
        keyword = @scanner.scan(KEYWORD)
        case keyword
        when "true" then true
        when "false" then false
        when "null" then nil
        when nil
          @scanner.pos += 1 # a stray delimiter: ")", ">", "{" or "}"
          parse_value
        else raise Prawn::Errors::MalformedPDF, "Unexpected #{keyword[0, 20].inspect} at #{@scanner.pos}"
        end
      end

      def parse_dictionary
        @scanner.pos += 2
        dictionary = {}
        loop do
          skip_whitespace
          break if @scanner.skip(/>>/n)
          raise Prawn::Errors::MalformedPDF, "Unterminated dictionary" if @scanner.eos?

          unless @scanner.peek_byte == 47
            parse_value # a value without its key: dropped, as viewers do
            next
          end

          key = name_bytes.to_sym
          skip_whitespace
          break if @scanner.skip(/>>/n)

          dictionary[key] = parse_value
        end
        dictionary
      end

      def parse_array
        @scanner.pos += 1
        array = []
        loop do
          skip_whitespace
          break if @scanner.skip(/\]/n)
          raise Prawn::Errors::MalformedPDF, "Unterminated array" if @scanner.eos?

          array << parse_value
        end
        array
      end

      def parse_hex_string
        @scanner.pos += 1
        hex = @scanner.scan(/[^>]*/n).delete("^0-9A-Fa-f")
        @scanner.skip(/>/n)
        ByteString.new([hex].pack("H*"))
      end

      def parse_literal_string
        @scanner.pos += 1
        output = +"".b
        depth = 1
        loop do
          output << @scanner.scan(/[^\\()]*/n)
          case @scanner.getch
          when "("
            depth += 1
            output << "("
          when ")"
            depth -= 1
            break if depth.zero?

            output << ")"
          when "\\" then output << literal_escape
          when nil then break
          end
        end
        ByteString.new(output)
      end

      def literal_escape
        if (octal = @scanner.scan(/[0-7]{1,3}/n))
          (octal.to_i(8) & 0xFF).chr
        elsif @scanner.skip(/\r\n|\r|\n/n)
          ""
        else
          character = @scanner.getch.to_s
          LITERAL_ESCAPES.fetch(character, character)
        end
      end
    end
  end
end
