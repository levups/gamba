module Prawn::SVG
  class Gradients
    def initialize(document)
      @document = document
      @gradients_by_id = {}
      @resolving = {}
    end

    def [](id)
      id &&= id.strip
      return unless id && id != ""

      if (element = @gradients_by_id[id])
        element
      # Gamba: a gradient or pattern whose href chain comes back to itself stops there, without a parent, and a
      # gradient left without stops paints nothing instead of failing to render.
      elsif !@resolving.key?(id) && (raw_element = find_raw_gradient_element_by_id(id))
        @resolving[id] = true
        begin
          # Gamba: only one that registered itself, which a gradient without stops never does.
          create_gradient_element(raw_element)
          @gradients_by_id[id]
        ensure
          @resolving.delete(id)
        end
      end
    end

    def []=(id, gradient)
      @gradients_by_id[id] = gradient
    end

    private

    PAINT_SERVER_CLASSES = [Elements::Gradient, Elements::Pattern].freeze

    def find_raw_gradient_element_by_id(id)
      raw_element = find_raw_element_by_id(id)
      raw_element if gradient_element?(raw_element)
    end

    def create_gradient_element(raw_element)
      element_class = Elements::TAG_CLASS_MAPPING[raw_element.name.to_sym]
      element_class.new(@document, raw_element, [], new_state).tap(&:process)
    end

    def find_raw_element_by_id(id)
      @document.raw_element_by_id(id)
    end

    def gradient_element?(raw_element)
      return false if raw_element.nil? || raw_element.name.nil?

      PAINT_SERVER_CLASSES.include?(Elements::TAG_CLASS_MAPPING[raw_element.name.to_sym])
    end

    def new_state
      State.new.tap do |state|
        state.viewport_sizing = @document.sizing
      end
    end
  end
end
