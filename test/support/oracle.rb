# frozen_string_literal: true

require "bundler"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../lib/gamba/pdf_check"

# Renders the same examples with Prawn and with Gamba, each in its own process, and lists what tells their PDFs
# apart: pages, text and its positions, pixels, validity, weight.
module Oracle
  ROOT = File.expand_path("../..", __dir__)
  MANUAL_DIRECTORY = File.join(ROOT, "corpus/cache/prawn/manual")
  RENDER_SCRIPT = File.join(__dir__, "oracle_render.rb")
  # Every encrypted example of Prawn's security chapter uses this user password; the tools ignore it elsewhere.
  MANUAL_USER_PASSWORD = "foo"
  Gamba::PdfCheck.password = MANUAL_USER_PASSWORD

  ENGINES = {
    "prawn" => {gemfile: File.join(ROOT, "oracle/Gemfile"), load_path: []},
    # The bundle the tests run in: CI runs them under each Rails's gemfile, the others' gems not installed.
    "gamba" => {gemfile: File.expand_path(ENV["BUNDLE_GEMFILE"].to_s.empty? ? "Gemfile" : ENV["BUNDLE_GEMFILE"], ROOT), load_path: ["-I", File.join(ROOT, "lib")]}
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

  def self.render(engine, paths, directory, environment = {})
    FileUtils.rm_rf(directory)
    settings = ENGINES.fetch(engine)
    command = ["bundle", "exec", "ruby", *settings[:load_path], RENDER_SCRIPT, directory, *paths]
    _output, errors, status = Bundler.with_unbundled_env { Open3.capture3(environment.merge("BUNDLE_GEMFILE" => settings[:gemfile]), *command) }
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

  # Where Prawn crashes on a bug of test/divergences.yml (prawn_raises), the candidate writes a valid PDF instead.
  def self.fixed_crash_differences(reference, candidate, name, error_class)
    return ["Prawn no longer raises #{error_class}"] unless self.error_class(reference, name) == error_class

    candidate_error = read_if_present(candidate.directory, "#{name}.error")
    return ["#{candidate.engine} raises #{candidate_error.lines.first.chomp}"] if candidate_error

    pdf = File.join(candidate.directory, "#{name}.pdf")
    return ["no PDF written"] unless File.exist?(pdf)

    [invalidity(pdf)].compact.map { "invalid PDF: #{_1}" }
  end

  # Whether Prawn, rendered with a prawn_switch of test/divergences.yml, went where the switch changes what it draws.
  def self.switched?(rendering, name)
    File.exist?(File.join(rendering.directory, "#{name}.switched"))
  end

  def self.error_class(rendering, name)
    read_if_present(rendering.directory, "#{name}.error")&.[](/\A\w+(?:::\w+)*/)
  end

  def self.pdf_differences(reference_pdf, candidate_pdf)
    return ["no PDF written"] unless File.exist?(candidate_pdf)

    differences = []
    problem = invalidity(candidate_pdf)
    differences << "invalid PDF: #{problem}" if problem
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

  # The comparisons themselves are Gamba::PdfCheck's, which applications' tests use too: one implementation.
  def self.invalidity(pdf)
    Gamba::PdfCheck.invalidity(pdf)
  end

  def self.text_differences(reference_pdf, candidate_pdf)
    Gamba::PdfCheck.text_differences(reference_pdf, candidate_pdf)
  end

  def self.text_layout(pdf)
    Gamba::PdfCheck.text_layout(pdf)
  end

  def self.pixel_differences(reference_pdf, candidate_pdf)
    Gamba::PdfCheck.pixel_differences(reference_pdf, candidate_pdf)
  end

  def self.rendered_pixel_differences(reference_pdf, candidate_pdf)
    Gamba::PdfCheck.rendered_pixel_differences(reference_pdf, candidate_pdf)
  end

  def self.with_neutral_subset_tags(pdf, path)
    Gamba::PdfCheck.with_neutral_subset_tags(pdf, path)
  end

  def self.rasterize(pdf, prefix)
    Gamba::PdfCheck.rasterize(pdf, prefix)
  end

  def self.mutool(*arguments, pdf)
    Gamba::PdfCheck.mutool(*arguments, pdf)
  end

  def self.read_if_present(directory, filename)
    path = File.join(directory, filename)
    File.read(path) if File.exist?(path)
  end
end
