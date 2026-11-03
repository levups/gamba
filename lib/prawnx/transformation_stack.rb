# frozen_string_literal: true

module Prawn
  # The current transformation matrix, tracked alongside the graphic state so gradients and soft masks can be
  # placed in page space.
  module TransformationStack
    IDENTITY = [1, 0, 0, 1, 0, 0].freeze

    def add_to_transformation_stack(a, b, c, d, e, f)
      @transformation_stack ||= [IDENTITY.dup]
      @transformation_stack.push(multiply(@transformation_stack.last, [a, b, c, d, e, f]))
    end

    def save_transformation_stack
      @transformation_stack ||= [IDENTITY.dup]
      @saved_transformation_stack_lengths ||= []
      @saved_transformation_stack_lengths.push(@transformation_stack.length)
    end

    def restore_transformation_stack
      return if @saved_transformation_stack_lengths.nil? || @saved_transformation_stack_lengths.empty?

      @transformation_stack.pop(@transformation_stack.length - @saved_transformation_stack_lengths.pop)
    end

    def current_transformation_matrix_with_translation(x = 0, y = 0)
      a, b, c, d, e, f = (@transformation_stack || [IDENTITY]).last
      [a, b, c, d, (a * x) + (c * y) + e, (b * x) + (d * y) + f].map { Float(_1) }
    end

    private

    def multiply(first, second)
      a1, b1, c1, d1, e1, f1 = first
      a2, b2, c2, d2, e2, f2 = second
      [
        (a2 * a1) + (b2 * c1), (a2 * b1) + (b2 * d1),
        (c2 * a1) + (d2 * c1), (c2 * b1) + (d2 * d1),
        (e2 * a1) + (f2 * c1) + e1, (e2 * b1) + (f2 * d1) + f1
      ]
    end
  end
end
