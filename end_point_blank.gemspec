# frozen_string_literal: true

require_relative "lib/end_point_blank/version"

Gem::Specification.new do |spec|
  spec.name = "end_point_blank"
  spec.version = EndPointBlank::VERSION
  spec.authors = ["Robert A. Lasch"]
  spec.email = ["rlasch@gmail.com"]

  spec.summary = "Ruby/Rails client for EndPointBlank — endpoint tracking, authorization, and error/request/response/log reporting."
  spec.description = "EndPointBlank client library for Ruby. A framework-agnostic core runs in plain Ruby / Sinatra, with Rails supported as an auto-loaded adapter. Provides API endpoint tracking, authorization, and error/request/response/log reporting."
  spec.homepage = "https://github.com/EndPointBlank/end_point_blank_rails"
  spec.required_ruby_version = ">= 3.4.2"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/EndPointBlank/end_point_blank_rails"
  spec.metadata["changelog_uri"] = "https://github.com/EndPointBlank/end_point_blank_rails/releases"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "excon", "~> 1.0"
  spec.add_dependency "rack"
  spec.add_dependency "rexml"
  # Base64 was removed from Ruby's default gems as of 3.4; Authorization
  # uses it for the Basic-auth header, so declare it explicitly.
  spec.add_dependency "base64"
  spec.add_development_dependency "debug", ">= 1.0.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
