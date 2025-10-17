# frozen_string_literal: true

require_relative "lib/counting_semaphore/version"

Gem::Specification.new do |spec|
  spec.name = "counting_semaphore"
  spec.version = CountingSemaphore::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]

  spec.summary = "A counting semaphore implementation for Ruby with local and distributed (Redis) variants"
  spec.description = "Provides both local (in-process) and shared (Redis-based) counting semaphores for controlling concurrent access to resources"
  spec.homepage = "https://github.com/julik/counting_semaphore"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/julik/counting_semaphore"
  spec.metadata["changelog_uri"] = "https://github.com/julik/counting_semaphore/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      File.expand_path(f) == __FILE__
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "standard", ">= 1.35.1"
  spec.add_development_dependency "redis", "~> 5.0"
  spec.add_development_dependency "connection_pool", "~> 2.4"
end
