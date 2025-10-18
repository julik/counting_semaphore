require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

task :generate_typedefs do
  `bundle exec sord rbi/counting_semaphore.rbi`
  `bundle exec sord sig/counting_semaphore.rbs`
end

task default: [:test, :standard, :generate_typedefs]
