# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.test_files = FileList["test/*_test.rb"]
end
task default: :test

namespace :corpus do
  desc "Download the sources pinned in corpus/manifest.yml into corpus/cache"
  task :fetch do
    ruby "script/corpus_fetch.rb"
  end
end

desc "Compare PrawnX with Prawn on bench/documents and write docs/benchmarks.json"
task :bench do
  ruby "bench/compare.rb"
end

namespace :docs do
  desc "Highlight the code blocks of docs/*.html with Rouge"
  task :highlight do
    ruby "script/highlight_docs.rb"
  end

  desc "Fail if a code block of docs/*.html is not highlighted"
  task "highlight:check" do
    ruby "script/highlight_docs.rb", "--check"
  end
end
