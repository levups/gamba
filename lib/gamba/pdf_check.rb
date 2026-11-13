# frozen_string_literal: true

require "open3"
require "pathname"
require "tempfile"
require "tmpdir"

module Gamba
  # What tells two PDFs apart, or a PDF from a valid one, through tools that share no code with Gamba: MuPDF for the
  # text and its positions, MuPDF and Poppler for pixels, qpdf and Poppler for validity, veraPDF for PDF/A. Gamba's
  # own oracle compares it with Prawn this way; Gamba::Minitest and Gamba::RSpec put it in an application's tests.
  # A PDF is given as its bytes or as the path of a file.
  module PdfCheck
    # Each glyph: [character, font without its subset tag, size, x, y], positions in points from the top left.
    Page = Data.define(:size, :glyphs)

    RESOLUTION_DPI = 150
    POSITION_PRECISION_DIGITS = 2
    # Same character, font and size, at most this far apart: positions round to 0.01 on either side of a boundary.
    POSITION_TOLERANCE = 0.0101
    RENDERERS = {"MuPDF" => :rasterize, "Poppler" => :rasterize_with_poppler}.freeze
    QPDF_WARNINGS_EXIT_STATUS = 3
    TOOLS = {
      "mutool" => "brew install mupdf-tools, or apt-get install mupdf-tools",
      "pdftoppm" => "brew install poppler, or apt-get install poppler-utils",
      "pdftotext" => "brew install poppler, or apt-get install poppler-utils",
      "qpdf" => "brew install qpdf, or apt-get install qpdf",
      "verapdf" => "brew install verapdf, or https://verapdf.org/software/"
    }.freeze

    # Raised when a check needs a tool that is not installed: the message names the install command.
    class ToolMissing < StandardError; end

    class << self
      # A password encrypted PDFs open with: the tools are given it when they cannot open one without.
      attr_accessor :password

      # The pages of the PDF, their text read by MuPDF.
      def text_layout(pdf)
        with_path(pdf) { |path| parse_text(mutool("draw", "-F", "stext", "-o", "-", path)) }
      end

      # The text of each page by line, top to bottom: what a reader sees, words joined.
      def text_lines(pdf)
        text_layout(pdf).map { |page| page.glyphs.group_by(&:last).sort.map! { |_y, glyphs| glyphs.map(&:first).join } }
      end

      # What makes qpdf or Poppler find the PDF broken, nil when nothing does. qpdf exits 3 for warnings: a PDF readers
      # have to repair is not a valid one. Poppler checks the operands of content stream operators, which qpdf does not.
      def invalidity(pdf)
        with_path(pdf) do |path|
          output, status = run("qpdf", "--check", path)
          output, status = run("qpdf", "--check", "--password=#{password}", path) if password && output.include?("invalid password")
          next output.lines.grep(/WARNING|ERROR|error/).first(3).join.strip.then { |problem| problem.empty? ? "qpdf exit #{status.exitstatus}" : problem } unless status.success?

          errors, _status = run("pdftotext", *(password ? ["-upw", password] : []), path, File::NULL)
          errors.lines.grep(/Syntax Error/).first(3).join.strip.then { |problem| problem unless problem.empty? }
        end
      end

      # What veraPDF finds against the PDF/A flavour, nil when it passes.
      def pdf_a_failure(pdf, flavour: "3b")
        with_path(pdf) do |path|
          report, _status = run("verapdf", "--flavour", flavour, "--format", "text", path)
          report.start_with?("PASS") ? nil : report.strip
        end
      end

      # Every difference between the pages of two PDFs: their number and sizes, each glyph with its font and position,
      # then pixel rows in MuPDF and in Poppler. Empty when a reader could not tell them apart.
      def page_differences(expected, actual)
        with_path(expected) do |expected_path|
          with_path(actual) do |actual_path|
            text_differences(expected_path, actual_path) + pixel_differences(expected_path, actual_path)
          end
        end
      end

      def text_differences(expected, actual)
        expected_pages = text_layout(expected)
        actual_pages = text_layout(actual)
        return ["#{actual_pages.size} pages instead of #{expected_pages.size}"] if expected_pages.size != actual_pages.size

        expected_pages.zip(actual_pages).each_with_index.filter_map do |(expected_page, actual_page), index|
          next if expected_page.size == actual_page.size && expected_page.glyphs.size == actual_page.glyphs.size &&
            expected_page.glyphs.zip(actual_page.glyphs).all? { |expected_glyph, actual_glyph| same_glyph?(expected_glyph, actual_glyph) }
          next "page #{index + 1}: size #{actual_page.size} instead of #{expected_page.size}" if expected_page.size != actual_page.size

          position = expected_page.glyphs.zip(actual_page.glyphs).index { |expected_glyph, actual_glyph| !same_glyph?(expected_glyph, actual_glyph) }
          next "page #{index + 1}: #{actual_page.glyphs.size} glyphs instead of #{expected_page.glyphs.size}" unless position

          "page #{index + 1}: glyph #{position} is #{actual_page.glyphs[position].inspect} instead of #{expected_page.glyphs[position].inspect}"
        end
      end

      def same_glyph?(expected_glyph, actual_glyph)
        return false if actual_glyph.nil? || expected_glyph.first(3) != actual_glyph.first(3)

        expected_glyph.last(2).zip(actual_glyph.last(2)).all? { |expected, actual| (expected - actual).abs <= POSITION_TOLERANCE }
      end

      # Two renderers that share no code, MuPDF and Poppler, must each draw both documents identically. Subset tags
      # are made the same first: MuPDF hints glyphs differently whether a tag is valid or not.
      def pixel_differences(expected, actual)
        with_path(expected) do |expected_path|
          with_path(actual) do |actual_path|
            Dir.mktmpdir do |directory|
              expected_path = with_neutral_subset_tags(expected_path, File.join(directory, "expected.pdf"))
              actual_path = with_neutral_subset_tags(actual_path, File.join(directory, "actual.pdf"))
              rendered_pixel_differences(expected_path, actual_path)
            end
          end
        end
      end

      def rendered_pixel_differences(expected, actual)
        RENDERERS.flat_map do |renderer, rasterizer|
          Dir.mktmpdir do |directory|
            expected_images = send(rasterizer, expected, File.join(directory, "expected"))
            actual_images = send(rasterizer, actual, File.join(directory, "actual"))
            expected_images.zip(actual_images).each_with_index.filter_map do |(expected_image, actual_image), index|
              next if actual_image.nil? || File.binread(expected_image) == File.binread(actual_image)

              "page #{index + 1}: #{differing_rows(expected_image, actual_image)} pixel rows differ at #{RESOLUTION_DPI} dpi#{" in #{renderer}" unless renderer == "MuPDF"}"
            end
          end
        end
      end

      # Each page as an image file, by MuPDF.
      def rasterize(pdf, prefix)
        mutool("draw", "-r", RESOLUTION_DPI.to_s, "-o", "#{prefix}-%04d.pnm", pdf)
        Dir["#{prefix}-*.pnm"].sort
      end

      def rasterize_with_poppler(pdf, prefix)
        _output, status = run("pdftoppm", "-r", RESOLUTION_DPI.to_s, pdf, prefix)
        run("pdftoppm", "-r", RESOLUTION_DPI.to_s, "-upw", password, pdf, prefix) if password && !status.success?
        Dir["#{prefix}-*.ppm"].sort
      end

      def mutool(*arguments, path)
        output, errors, status = Open3.capture3(tool("mutool"), arguments.first, "-q", *password_arguments("-p"), *arguments.drop(1), path, binmode: true)
        raise "mutool #{arguments.first} failed on #{path}: #{errors}" unless status.success?

        output
      end

      # The bytes of a PDF written to a file for the tools, or the path given (a String or a Pathname).
      def with_path(pdf)
        return yield pdf.to_s if pdf.is_a?(Pathname) || (!pdf.b.start_with?("%PDF") && !pdf.include?("\0") && File.file?(pdf))

        Tempfile.create(["gamba-check", ".pdf"]) do |file|
          file.binmode
          file.write(pdf)
          file.flush
          yield file.path
        end
      end

      # The PDF written to path with every subset tag the same. Only names after /BaseFont or /FontName change: compressed stream data can hold a tag's bytes by chance.
      def with_neutral_subset_tags(pdf, path)
        _output, status = run("qpdf", "--qdf", "--object-streams=disable", "--stream-data=preserve", pdf, path)
        return pdf unless status.success? || status.exitstatus == QPDF_WARNINGS_EXIT_STATUS

        File.binwrite(path, File.binread(path).gsub(%r{(/(?:BaseFont|FontName)\s*)/[0-9A-Za-z]{6}\+}n, '\1/AAAAAA+'))
        path
      end

      private

      def parse_text(xml)
        xml.split("<page ").drop(1).map! do |page|
          font = nil
          glyphs = []
          page.scan(/<(font|char) ([^>]*)>/) do |element, attributes|
            value_by_name = attributes.scan(/(\w+)="([^"]*)"/).to_h
            if element == "font"
              font = [value_by_name.fetch("name").sub(/\A[A-Z]{6}\+/, ""), value_by_name.fetch("size").to_f.round(POSITION_PRECISION_DIGITS)]
            else
              position = value_by_name.fetch_values("x", "y").map { _1.to_f.round(POSITION_PRECISION_DIGITS) }
              glyphs << [value_by_name.fetch("c"), *font, *position]
            end
          end
          Page.new(size: page[/width="[^"]*" height="[^"]*"/], glyphs:)
        end
      end

      def differing_rows(expected_image, actual_image)
        expected_rows = pnm_rows(expected_image)
        actual_rows = pnm_rows(actual_image)
        return "all" if expected_rows.size != actual_rows.size

        expected_rows.zip(actual_rows).count { |expected_row, actual_row| expected_row != actual_row }
      end

      def pnm_rows(image)
        content = File.binread(image)
        header = content[/\AP\d\s+\d+\s+\d+\s+\d+\s/]
        _format, width, height = header.split.map { Integer(_1[/\d+/]) }
        row_bytes = width * (content.start_with?("P5") ? 1 : 3)
        Array.new(height) { |row| content.byteslice(header.bytesize + (row * row_bytes), row_bytes) }
      end

      def password_arguments(flag)
        password ? [flag, password] : []
      end

      def run(name, *arguments)
        Open3.capture2e(tool(name), *arguments)
      end

      def tool(name)
        @found ||= {}
        @found[name] ||= ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { File.join(_1, name) }.find { File.executable?(_1) } ||
          raise(ToolMissing, "#{name} is not installed: #{TOOLS.fetch(name)}")
      end
    end
  end
end
