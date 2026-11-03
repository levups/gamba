# frozen_string_literal: true

require "bundler"
require "fileutils"
require "open3"
require "tmpdir"

# Renders the same examples with Prawn and with PrawnX, each in its own process, and lists what tells their PDFs
# apart: pages, text and its positions, pixels, validity, weight.
module Oracle
  ROOT = File.expand_path("../..", __dir__)
  MANUAL_DIRECTORY = File.join(ROOT, "corpus/cache/prawn/manual")
  RENDER_SCRIPT = File.join(__dir__, "oracle_render.rb")
  RESOLUTION_DPI = 150
  POSITION_PRECISION_DIGITS = 2
  # Every encrypted example of Prawn's security chapter uses this user password; mutool and qpdf ignore it elsewhere.
  MANUAL_USER_PASSWORD = "foo"

  ENGINES = {
    "prawn" => {gemfile: File.join(ROOT, "oracle/Gemfile"), load_path: []},
    "prawnx" => {gemfile: File.join(ROOT, "Gemfile"), load_path: ["-I", File.join(ROOT, "lib")]}
  }.freeze

  Rendering = Data.define(:engine, :directory, :failure)

  EXAMPLES_DIRECTORY = File.join(ROOT, "test/oracle_examples")

  def self.manual_chapters
    Dir[File.join(MANUAL_DIRECTORY, "*/*.rb")].sort
  end

  # Prawn's manual, then documents of our own for what the manual does not show.
  def self.example_files
    manual_chapters + table_manual_examples + sample_svgs + Dir[File.join(EXAMPLES_DIRECTORY, "*.rb")].sort
  end

  def self.sample_svgs
    Dir[File.join(ROOT, "corpus/cache/prawn-svg/spec/sample_svg/*.svg")].sort
  end

  # prawn-table's manual, without its table of contents.
  def self.table_manual_examples
    Dir[File.join(ROOT, "corpus/cache/prawn-table/manual/table/*.rb")].sort.select { File.read(_1).include?("Example.generate(filename)") }
  end

  def self.render(engine, paths, directory)
    FileUtils.rm_rf(directory)
    settings = ENGINES.fetch(engine)
    command = ["bundle", "exec", "ruby", *settings[:load_path], RENDER_SCRIPT, directory, *paths]
    _output, errors, status = Bundler.with_unbundled_env { Open3.capture3({"BUNDLE_GEMFILE" => settings[:gemfile]}, *command) }
    Rendering.new(engine:, directory:, failure: (errors.lines.last&.chomp unless status.success?))
  end

  def self.example_names(rendering)
    Dir.children(rendering.directory).map { File.basename(_1, ".*") }.uniq.sort
  end

  def self.differences(reference, candidate, name)
    reference_error = read_if_present(reference.directory, "#{name}.error")
    candidate_error = read_if_present(candidate.directory, "#{name}.error")
    return ["#{candidate.engine} cannot run: #{candidate.failure}"] if candidate.failure
    return ["#{candidate.engine} raises #{candidate_error.lines.first.chomp}"] if candidate_error && !reference_error
    return ["#{candidate.engine} does not raise #{reference_error.lines.first.chomp}"] if reference_error && !candidate_error
    return error_class_differences(reference_error, candidate_error) if reference_error

    pdf_differences(File.join(reference.directory, "#{name}.pdf"), File.join(candidate.directory, "#{name}.pdf"))
  end

  def self.pdf_differences(reference_pdf, candidate_pdf)
    return ["no PDF written"] unless File.exist?(candidate_pdf)

    differences = []
    qpdf_problem = invalidity(candidate_pdf)
    differences << "invalid PDF: #{qpdf_problem}" if qpdf_problem
    if File.size(candidate_pdf) > File.size(reference_pdf)
      differences << "heavier: #{File.size(candidate_pdf)} bytes instead of #{File.size(reference_pdf)}"
    end
    differences.concat(text_differences(reference_pdf, candidate_pdf))
    differences.concat(pixel_differences(reference_pdf, candidate_pdf))
  end

  def self.error_class_differences(reference_error, candidate_error)
    reference_class = reference_error[/\A\w+(?:::\w+)*/]
    candidate_class = candidate_error[/\A\w+(?:::\w+)*/]
    (reference_class == candidate_class) ? [] : ["raises #{candidate_class} instead of #{reference_class}"]
  end

  # qpdf exits with 3 for warnings: a PDF readers have to repair is not a valid one.
  def self.invalidity(pdf)
    output, status = Open3.capture2e("qpdf", "--check", pdf)
    output, status = Open3.capture2e("qpdf", "--check", "--password=#{MANUAL_USER_PASSWORD}", pdf) if output.include?("invalid password")
    output.lines.grep(/WARNING|ERROR|error/).first(3).join.strip.then { _1.empty? ? "qpdf exit #{status.exitstatus}" : _1 } unless status.success?
  end

  def self.text_differences(reference_pdf, candidate_pdf)
    reference_pages = text_layout(reference_pdf)
    candidate_pages = text_layout(candidate_pdf)
    return ["#{candidate_pages.size} pages instead of #{reference_pages.size}"] if reference_pages.size != candidate_pages.size

    reference_pages.zip(candidate_pages).each_with_index.filter_map do |(reference_page, candidate_page), index|
      next if reference_page.size == candidate_page.size && reference_page.glyphs.size == candidate_page.glyphs.size &&
        reference_page.glyphs.zip(candidate_page.glyphs).all? { |reference_glyph, candidate_glyph| same_glyph?(reference_glyph, candidate_glyph) }
      next "page #{index + 1}: size #{candidate_page.size} instead of #{reference_page.size}" if reference_page.size != candidate_page.size

      position = reference_page.glyphs.zip(candidate_page.glyphs).index { |reference_glyph, candidate_glyph| !same_glyph?(reference_glyph, candidate_glyph) }
      next "page #{index + 1}: #{candidate_page.glyphs.size} glyphs instead of #{reference_page.glyphs.size}" unless position

      "page #{index + 1}: glyph #{position} is #{candidate_page.glyphs[position].inspect} instead of #{reference_page.glyphs[position].inspect}"
    end
  end

  POSITION_TOLERANCE = 0.0101

  # Same character, font and size, at most 0.01 pt apart: positions round to 0.01 on either side of a boundary.
  def self.same_glyph?(reference_glyph, candidate_glyph)
    return false if candidate_glyph.nil? || reference_glyph.first(3) != candidate_glyph.first(3)

    reference_glyph.last(2).zip(candidate_glyph.last(2)).all? { |reference, candidate| (reference - candidate).abs <= POSITION_TOLERANCE }
  end

  # Each glyph is [character, font without its subset tag, font size, x, y].
  Page = Data.define(:size, :glyphs)

  def self.text_layout(pdf)
    xml = mutool("draw", "-F", "stext", "-o", "-", pdf)
    xml.split("<page ").drop(1).map do |page|
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

  # Two renderers that share no code, MuPDF and Poppler, must each draw both documents identically.
  RENDERERS = {"MuPDF" => :rasterize, "Poppler" => :rasterize_with_poppler}.freeze
  QPDF_WARNINGS_EXIT_STATUS = 3

  def self.pixel_differences(reference_pdf, candidate_pdf)
    Dir.mktmpdir do |tagged_directory|
      reference_pdf = with_neutral_subset_tags(reference_pdf, File.join(tagged_directory, "reference.pdf"))
      candidate_pdf = with_neutral_subset_tags(candidate_pdf, File.join(tagged_directory, "candidate.pdf"))
      rendered_pixel_differences(reference_pdf, candidate_pdf)
    end
  end

  def self.rendered_pixel_differences(reference_pdf, candidate_pdf)
    RENDERERS.flat_map do |renderer, rasterizer|
      Dir.mktmpdir do |directory|
        reference_images = send(rasterizer, reference_pdf, File.join(directory, "reference"))
        candidate_images = send(rasterizer, candidate_pdf, File.join(directory, "candidate"))
        reference_images.zip(candidate_images).each_with_index.filter_map do |(reference_image, candidate_image), index|
          next if candidate_image.nil? || File.binread(reference_image) == File.binread(candidate_image)

          "page #{index + 1}: #{differing_rows(reference_image, candidate_image)} pixel rows differ at #{RESOLUTION_DPI} dpi#{" in #{renderer}" unless renderer == "MuPDF"}"
        end
      end
    end
  end

  # MuPDF hints some glyphs differently whether a font's subset tag is valid or not, and Prawn's lowercase hexadecimal
  # tags are not ("exactly six uppercase letters", ISO 32000-1 §9.6.4): both documents get the same tag before drawing.
  # Streams stay compressed, so no byte of a font program can be mistaken for a tag.
  def self.with_neutral_subset_tags(pdf, path)
    _output, status = Open3.capture2e("qpdf", "--qdf", "--object-streams=disable", "--stream-data=preserve", pdf, path)
    return pdf unless status.success? || status.exitstatus == QPDF_WARNINGS_EXIT_STATUS

    File.binwrite(path, File.binread(path).gsub(%r{/[0-9A-Za-z]{6}\+}n, "/AAAAAA+"))
    path
  end

  def self.rasterize_with_poppler(pdf, prefix)
    _output, status = Open3.capture2e("pdftoppm", "-r", RESOLUTION_DPI.to_s, pdf, prefix)
    Open3.capture2e("pdftoppm", "-r", RESOLUTION_DPI.to_s, "-upw", MANUAL_USER_PASSWORD, pdf, prefix) unless status.success?
    Dir["#{prefix}-*.ppm"].sort
  end

  def self.rasterize(pdf, prefix)
    mutool("draw", "-r", RESOLUTION_DPI.to_s, "-o", "#{prefix}-%04d.pnm", pdf)
    Dir["#{prefix}-*.pnm"].sort
  end

  def self.differing_rows(reference_image, candidate_image)
    reference_rows = pnm_rows(reference_image)
    candidate_rows = pnm_rows(candidate_image)
    return "all" if reference_rows.size != candidate_rows.size

    reference_rows.zip(candidate_rows).count { |reference_row, candidate_row| reference_row != candidate_row }
  end

  def self.pnm_rows(image)
    content = File.binread(image)
    header = content[/\AP\d\s+\d+\s+\d+\s+\d+\s/]
    _format, width, height = header.split.map { Integer(_1[/\d+/]) }
    row_bytes = width * (content.start_with?("P5") ? 1 : 3)
    Array.new(height) { content.byteslice(header.bytesize + _1 * row_bytes, row_bytes) }
  end

  def self.mutool(*arguments, pdf)
    output, errors, status = Open3.capture3("mutool", *arguments.take(1), "-q", "-p", MANUAL_USER_PASSWORD, *arguments.drop(1), pdf, binmode: true)
    raise "mutool #{arguments.first} failed on #{pdf}: #{errors}" unless status.success?

    output
  end

  def self.read_if_present(directory, filename)
    path = File.join(directory, filename)
    File.read(path) if File.exist?(path)
  end
end
