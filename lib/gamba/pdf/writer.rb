# frozen_string_literal: true

require "digest/md5"
require "zlib"

module PDF
  module Core
    # Writes a PDF 1.5 file: streams compressed, every other object packed into one compressed object stream, and
    # a compressed cross-reference stream instead of the xref table (ISO 32000-1 §7.5.7, §7.5.8).
    class Writer
      MINIMUM_VERSION = 1.5
      BINARY_MARKER = "%\xE2\xE3\xCF\xD3\n".b

      def self.call(...)
        new(...).call
      end

      def initialize(objects:, root:, info:, version:, trailer: {}, encryption: nil, identified: false)
        @objects = objects
        @root = root
        @info = info
        @version = [version, MINIMUM_VERSION].max
        @trailer = trailer
        return unless encryption || identified

        file_identifier = PDF::Core::ByteString.new(document_digest(encryption&.identifier_secret))
        @trailer = trailer.merge(ID: [file_identifier, file_identifier])
        return unless encryption

        @encryption_key = encryption.key(file_identifier)
        @trailer[:Encrypt] = encryption.dictionary(file_identifier)
      end

      def call
        output = "%PDF-#{version}\n".b << BINARY_MARKER
        location_by_identifier = {}

        stream_objects, packed_objects = objects.partition(&:stream?)
        stream_objects.each do |reference|
          location_by_identifier[reference.identifier] = [1, output.bytesize]
          output << indirect_stream(reference.identifier, reference.data, reference.stream, compressed: !reference.uncompressed)
        end

        object_stream_identifier = objects.size + 1
        unless packed_objects.empty?
          location_by_identifier[object_stream_identifier] = [1, output.bytesize]
          output << object_stream(object_stream_identifier, packed_objects, location_by_identifier)
        end

        cross_reference_identifier = object_stream_identifier + 1
        location_by_identifier[cross_reference_identifier] = [1, output.bytesize]
        output << cross_reference_stream(cross_reference_identifier, location_by_identifier)
      end

      private

      attr_reader :objects, :root, :info, :version, :trailer

      # A file identifier derived from the document's content, so the same document always gets the same one; an
      # encrypted document's mixes in its passwords.
      def document_digest(secret)
        digest = Digest::MD5.new
        digest << secret if secret
        objects.each do |reference|
          digest << PDF::Core.serialize(reference.data)
          digest << reference.stream if reference.stream?
        end
        digest.digest
      end

      # Streams are encrypted once compressed; the cross-reference stream never is (ISO 32000-1 §7.5.8.4).
      def indirect_stream(identifier, dictionary, bytes, encrypted: true, compressed: true)
        compressed &&= dictionary[:Filter].nil?
        bytes = Zlib::Deflate.deflate(bytes) if compressed
        bytes = Prawn::Document::Arcfour.new(Prawn::Document::Security.object_key(@encryption_key, identifier, 0)).encrypt(bytes) if @encryption_key && encrypted
        dictionary = dictionary.merge(Length: bytes.bytesize)
        dictionary[:Filter] = :FlateDecode if compressed
        "#{identifier} 0 obj\n#{PDF::Core.serialize(dictionary)}\nstream\n".b << bytes.b << "\nendstream\nendobj\n"
      end

      def object_stream(identifier, references, location_by_identifier)
        offsets = +""
        body = +""
        references.each_with_index do |reference, index|
          location_by_identifier[reference.identifier] = [2, identifier, index]
          offsets << "#{reference.identifier} #{body.bytesize} "
          body << PDF::Core.serialize(reference.data) << "\n"
        end
        dictionary = {Type: :ObjStm, N: references.size, First: offsets.bytesize}
        indirect_stream(identifier, dictionary, offsets << body)
      end

      # Each row is one byte of type, then the offset or the object stream, then the generation or the index.
      def cross_reference_stream(identifier, location_by_identifier)
        size = identifier + 1
        offset_width = [(location_by_identifier.values.map { _1[1] }.max.bit_length + 7) / 8, 1].max
        rows = (+"\x00".b) << ("\x00" * offset_width).b << "\xFF\xFF".b
        (1...size).each do |object_identifier|
          type, field, generation_or_index = location_by_identifier.fetch(object_identifier)
          rows << type.chr << [field].pack("Q>").byteslice(8 - offset_width, offset_width) << [generation_or_index.to_i].pack("n")
        end
        dictionary = {Type: :XRef, Size: size, W: [1, offset_width, 2], Root: root, Info: info}.merge(trailer)
        indirect_stream(identifier, dictionary, rows, encrypted: false) << "startxref\n#{location_by_identifier.fetch(identifier)[1]}\n%%EOF\n"
      end
    end
  end
end
