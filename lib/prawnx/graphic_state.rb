# frozen_string_literal: true

module PDF::Core
  # What a PDF `q` saves and `Q` restores, as far as PrawnX writes it.
  class GraphicState
    UNDASHED = {dash: nil, space: nil, phase: 0}.freeze
    # The text state parameters Prawn sets, as each block writes them, in the order a new page writes them back.
    DEFAULT_TEXT_STATE = {text_rendering_mode: :fill, character_spacing: 0, word_spacing: 0, horizontal_text_scaling: 100, rise: 0}.freeze

    attr_accessor :color_space, :dash, :cap_style, :join_style, :line_width, :fill_color, :stroke_color, :text_state

    def initialize(previous_state = nil)
      if previous_state
        @color_space = previous_state.color_space.dup
        @fill_color = previous_state.fill_color.dup
        @stroke_color = previous_state.stroke_color.dup
        @dash = previous_state.dash.dup
        @cap_style = previous_state.cap_style
        @join_style = previous_state.join_style
        @line_width = previous_state.line_width
        @text_state = previous_state.text_state
      else
        @color_space = {}
        @fill_color = "000000"
        @stroke_color = "000000"
        @dash = UNDASHED.dup
        @cap_style = :butt
        @join_style = :miter
        @line_width = 1
        @text_state = DEFAULT_TEXT_STATE
      end
    end

    def dup
      GraphicState.new(self)
    end

    def dash_setting
      return "[] 0 d" unless dash[:dash]

      lengths = dash[:dash].is_a?(Array) ? dash[:dash] : [dash[:dash], dash[:space]]
      "[#{PDF::Core.real_params(lengths)}] #{PDF::Core.real(dash[:phase])} d"
    end
  end
end
