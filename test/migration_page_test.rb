# frozen_string_literal: true

require_relative "test_helper"
require "cgi"
require "open3"
require "prawn"
require_relative "../bench/native_bench"

# Every code sample of docs/migration.html runs as a reader would run it, in a directory holding the files it names.
# The three stages show the invoice code `rake bench` measures and draw the same invoice, and each Prawn idiom draws
# the same text as the native code beside it.
class MigrationPageTest < Minitest::Test
  PAGE = File.join(Oracle::ROOT, "docs/migration.html")
  FILES = {"DejaVuSans.ttf" => "fonts/DejaVuSans.ttf", "DejaVuSans-Bold.ttf" => "fonts/DejaVuSans-Bold.ttf", "letterhead.jpg" => "images/letterhead.jpg"}.freeze
  CODE = %r{<pre><code class="language-ruby">(.*?)</code></pre>}m

  def setup
    skip CORPUS_MISSING_MESSAGE unless File.directory?(NativeBench::DATA_DIRECTORY)
  end

  def test_each_stage_shows_the_code_the_bench_measures
    assert_equal %w[bench/documents/invoice.rb bench/mixed/invoice.rb bench/native/invoice.rb], stages.map(&:first)

    stages.each do |bench, code|
      measured = File.read(File.join(Oracle::ROOT, bench)).lines.drop_while { _1.start_with?("#") }.join
      shown = code.lines[1...-1].map { _1.delete_prefix("  ") }.join

      assert_equal measured.gsub(%r{\#\{DATA_DIRECTORY\}/(fonts|images)/}, ""), shown, bench
    end
  end

  def test_the_stages_draw_the_same_invoice
    prawn, mixed, native = stages.map { |_bench, code| render(code) }

    assert_equal prawn, mixed, "a native block draws the table Prawn's code drew"
    assert_equal words(prawn), words(native)
  end

  def test_each_prawn_idiom_draws_the_same_text_as_its_native_code
    pairs = page.scan(%r{<div class="split">(.*?)(?=<h3>|</section>)}m).map { |(split)| split.scan(CODE).map { code(_1.first) } }

    assert_equal 5, pairs.size
    pairs.each do |prawn, native|
      assert_equal words(render(prawn)).sort, words(render(native)).sort, prawn.lines.first
    end
  end

  def test_every_sample_runs
    samples = page.scan(CODE).map { code(_1.first) }

    assert_equal 14, samples.size
    samples.each { |sample| refute_empty render(sample, writes: sample.include?("write(") || sample.include?("generate(")), sample.lines.first }
  end

  private

  def page
    @page ||= File.read(PAGE, encoding: Encoding::UTF_8)
  end

  def code(html)
    CGI.unescapeHTML(html.gsub(%r{</?span[^>]*>}, ""))
  end

  def stages
    page.scan(%r{<div class="stage" data-bench="([^"]+)">\s*#{CODE}}o).map { |bench, html| [bench, code(html)] }
  end

  # The PDF the sample writes, or what it returns when it writes none, rendered in a directory of its own.
  def render(sample, writes: true)
    Dir.mktmpdir do |directory|
      FILES.each { |name, path| FileUtils.ln_s(File.join(NativeBench::DATA_DIRECTORY, path), File.join(directory, name)) }
      Dir.chdir(directory) do
        result = Object.new.instance_eval { binding }.eval(sample, PAGE)
        next result.to_s unless writes

        written = Dir["*.pdf"]
        assert_equal 1, written.size, sample.lines.first
        File.binread(written.first)
      end
    end
  end

  def words(pdf)
    output, status = Open3.capture2("pdftotext", "-", "-", stdin_data: pdf, binmode: true)
    assert status.success?
    output.force_encoding(Encoding::UTF_8).split
  end
end
