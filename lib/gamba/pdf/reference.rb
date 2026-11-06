# frozen_string_literal: true

module PDF
  module Core
    # An indirect object: a number, its value and, for a stream, its bytes.
    class Reference
      attr_reader :identifier
      attr_accessor :data, :uncompressed
      # Written as a stream even without bytes, as image XObjects must be.
      attr_writer :stream, :empty_stream

      def initialize(identifier, data, stream = nil)
        @identifier = identifier
        @data = data
        @stream = stream
        @empty_stream = false
      end

      def to_s
        "#{identifier} 0 R"
      end

      # A reference becomes a stream once bytes are written to it: prawn-svg appends to ref!({}).stream.
      def stream
        @stream ||= +"".b
      end

      def stream?
        !@stream.nil? && (@empty_stream || !@stream.empty?)
      end
    end
  end
end
