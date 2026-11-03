module Prawn::SVG::PDFMatrix
  def load_matrix(matrix)
    if matrix.is_a?(Matrix) && matrix.row_count == 3 && matrix.column_count == 3
      matrix
    elsif matrix.is_a?(Array) && matrix.length == 6
      Matrix[
        [matrix[0], matrix[2], matrix[4]],
        [matrix[1], matrix[3], matrix[5]],
        [0.0, 0.0, 1.0]
      ]
    else
      raise ArgumentError, "unexpected matrix format"
    end
  end

  def matrix_for_pdf(matrix)
    # The first two rows, transposed and flattened, without the three intermediate arrays.
    first, second = matrix.to_a
    [first[0], second[0], first[1], second[1], first[2], second[2]]
  end

  def translation_matrix(x = 0, y = 0)
    Matrix[[1.0, 0.0, x.to_f], [0.0, 1.0, y.to_f], [0.0, 0.0, 1.0]]
  end

  def scale_matrix(x = 1, y = x)
    Matrix[[x.to_f, 0.0, 0.0], [0.0, y.to_f, 0.0], [0.0, 0.0, 1.0]]
  end

  def rotation_matrix(angle, space: :pdf)
    dir = (space == :svg) ? 1.0 : -1.0

    Matrix[
      [Math.cos(angle), -dir * Math.sin(angle), 0],
      [dir * Math.sin(angle), Math.cos(angle), 0],
      [0, 0, 1]
    ]
  end
end
