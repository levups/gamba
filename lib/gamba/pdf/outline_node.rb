# frozen_string_literal: true

module PDF
  module Core
    class OutlineRoot
      include Serializable

      attr_accessor :count, :first, :last

      def initialize
        @count = 0
      end

      def to_hash
        {Type: :Outlines, Count: count, First: first, Last: last}
      end
    end

    class OutlineItem
      include Serializable

      attr_accessor :count, :first, :last, :next, :prev, :parent, :title, :dest, :closed

      def initialize(title, parent, options)
        @closed = options[:closed]
        @title = title
        @parent = parent
        @count = 0
      end

      def to_hash
        {Title: title, Parent: parent, Count: closed ? -count : count, First: first, Last: last, Next: @next, Prev: prev, Dest: dest}.compact
      end
    end

    # A name tree kept as a single sorted leaf: valid at any size (ISO 32000-1 §7.9.6).
    class NameTree
      include Serializable

      def initialize
        @value_by_name = {}
      end

      def add(name, value)
        @value_by_name[name] = value
      end

      def to_hash
        {Names: @value_by_name.sort_by { |name, _| name.to_s }.flat_map { |name, value| [LiteralString.new(name.to_s), value] }}
      end
    end
  end
end
