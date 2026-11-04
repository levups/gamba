# frozen_string_literal: true

module Prawn
  # Content drawn once into a form XObject, then placed on any page by name.
  module Stamp
    def stamp(name)
      dictionary_name, dictionary = stamp_dictionary(name)
      add_content("/#{dictionary_name} Do")
      annotations = dictionary.data[:Annots]
      page.dictionary.data[:Annots] = (page.dictionary.data[:Annots] || []) | annotations if annotations&.any?
      page.xobjects[dictionary_name] = dictionary
    end

    def stamp_at(name, point, &)
      translate(point[0], point[1]) { stamp(name) }
    end

    def create_stamp(name, &)
      page.stamp_stream(create_stamp_dictionary(name), &)
    end

    private

    def stamp_dictionary_registry
      @stamp_dictionary_registry ||= {}
    end

    def stamp_dictionary(name)
      raise Errors::InvalidName if name.empty?
      raise Errors::UndefinedObjectName unless stamp_dictionary_registry.key?(name)

      stamp_dictionary_registry[name].values_at(:stamp_dictionary_name, :stamp_dictionary)
    end

    def create_stamp_dictionary(name)
      raise Errors::InvalidName if name.empty?
      raise Errors::NameTaken if stamp_dictionary_registry.key?(name)

      _left, _bottom, width, height = page.dimensions
      dictionary = ref!({Type: :XObject, Subtype: :Form, BBox: [0, 0, width, height]}, +"")
      stamp_dictionary_registry[name] = {stamp_dictionary_name: "Stamp#{stamp_dictionary_registry.length + 1}", stamp_dictionary: dictionary}
      dictionary
    end

    def freeze_stamp_graphics
      update_colors
      write_line_width
      write_stroke_cap_style
      write_stroke_join_style
      write_stroke_dash
    end
  end

  module SoftMask
    def soft_mask(&)
      min_version(1.4)
      group_attributes = ref!(Type: :Group, S: :Transparency, CS: :DeviceRGB, I: false, K: false)
      group = ref!({Type: :XObject, Subtype: :Form, BBox: page.dimensions, Group: group_attributes}, +"")
      page.stamp_stream(group, &)
      mask = ref!(Type: :Mask, S: :Luminosity, G: group)
      graphic_state_dictionary = ref!(Type: :ExtGState, SMask: mask, AIS: false, BM: :Normal, OP: false, op: false, OPM: 1, SA: true)

      registry_key = [page.dimensions, group.stream, page_count].hash
      @soft_mask_registry ||= {}
      unless @soft_mask_registry[registry_key]
        masks = page.resources[:ExtGState] ||= {}
        name = masks.empty? ? "GS1" : masks.keys.max.succ
        masks[name] = graphic_state_dictionary
        @soft_mask_registry[registry_key] = name
      end
      add_content("/#{@soft_mask_registry[registry_key]} gs")
      # Its ExtGState sets the blend mode back to Normal.
      graphic_state.blend_mode = nil
    end
  end
end
