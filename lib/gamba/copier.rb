# frozen_string_literal: true

module Gamba
  # Copies objects of a PDF written elsewhere into one being written, through the references a block makes: each
  # object once, those with the same content (references included) once in all, the rest when #finish is called.
  class Copier
    # References followed to tell whether two objects are the same: a chain deeper than this is copied unshared,
    # instead of overflowing the stack on a file that links its objects into a list as long as it likes.
    MAX_DESCRIBED_DEPTH = 32

    # shared and identifiers carry what was written from earlier files, so that a font they all use is written once.
    def initialize(reader, shared: {}, identifiers: {}, &reference)
      @reader = reader
      @shared = shared
      @identifiers = identifiers
      @reference = reference
      @copies = {}
      @pending = []
      @content_identifiers = {}
      @description_depth = 0
    end

    # An object of the source written by the caller as `copy`, so that a link to it lands on that copy; never shared.
    def place(number, copy)
      @copies[number] = copy
      @content_identifiers[number] = nil
    end

    # The value with each reference to the source replaced by one to its copy, written by #finish.
    def copy(value)
      case value
      when PDF::Core::Reader::Ref
        @copies[value.number] ||= begin
          identifier = content_identifier(value.number)
          identifier ? (@shared[identifier] ||= pending_copy(value.number)) : pending_copy(value.number)
        end
      when Hash then value.transform_values { copy(_1) }
      when Array then value.map { copy(_1) }
      else value
      end
    end

    def finish
      until @pending.empty?
        number, copy = @pending.pop
        value = @reader.object(number)
        if value.is_a?(PDF::Core::Reader::Stream)
          dictionary = value.dictionary.except(:Length)
          # The writer packs streams without bytes as plain objects: keep one byte of data instead.
          dictionary = dictionary.except(:Filter, :DecodeParms) if value.data.empty?
          copy.data = copy(dictionary)
          copy.stream = value.data.empty? ? +" " : +value.data
        else
          copy.data = copy(value)
        end
      end
    end

    private

    def pending_copy(number)
      @reference.call(nil).tap { @pending << [number, _1] }
    end

    # Objects with the same content, references included, are written once: the fonts, images and glyph procedures a
    # carrier repeats on every label. Pages, and annotations (whose place is their own), are never shared.
    def content_identifier(number)
      return @content_identifiers[number] if @content_identifiers.key?(number)
      return nil if @description_depth >= MAX_DESCRIBED_DEPTH

      @content_identifiers[number] = nil # an object reached again while describing it stays unshared
      @description_depth += 1
      begin
        value = @reader.object(number)
        key = if value.is_a?(PDF::Core::Reader::Stream)
          description = describe(value.dictionary.except(:Length))
          [description, value.data] if description
        elsif !(value.is_a?(Hash) && value.key?(:Rect))
          describe(value)
        end
      ensure
        @description_depth -= 1
      end
      @content_identifiers[number] = key && (@identifiers[key] ||= @identifiers.size)
    end

    def describe(value, description = +"")
      case value
      when PDF::Core::Reader::Ref
        identifier = content_identifier(value.number)
        identifier && description << "R" << identifier.to_s << " "
      when Hash
        description << "<<"
        value.each { |key, entry| describe(entry, description << PDF::Core.escape_name(key.name) << " ") || (return nil) }
        description << ">>"
      when Array
        description << "["
        value.each { describe(_1, description) || (return nil) }
        description << "]"
      when PDF::Core::ByteString then description << "(" << value.bytesize.to_s << ":" << value << ")"
      when PDF::Core::Name then description << PDF::Core.escape_name(value.value) << " "
      when PDF::Core::Real then description << value.source << " "
      else description << value.inspect << " "
      end
    end
  end
end
