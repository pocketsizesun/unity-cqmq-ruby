# frozen_string_literal: true

require_relative "lib/unity/cqmq/version"

Gem::Specification.new do |spec|
  spec.name          = "unity-cqmq"
  spec.version       = Unity::CQMQ::VERSION
  spec.authors       = ["Julien D."]
  spec.email         = ["julien@pocketsizesun.com"]

  spec.summary       = 'CQMQ - A request/response message queue based on SQS'
  spec.description   = "CQMQ is a request/response message queue that use AWS Simple Queue Service as message broker"
  spec.homepage      = "https://github.com/pocketsizesun/unity-cqmq-ruby"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.3.0")

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/pocketsizesun/unity-cqmq-ruby'
  spec.metadata['changelog_uri'] = "https://github.com/pocketsizesun/unity-cqmq-ruby"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'concurrent-ruby', '~> 1.1'
  spec.add_dependency 'connection_pool', '~> 2.2'

  # Uncomment to register a new dependency of your gem
  spec.add_development_dependency 'aws-sdk-sqs'
  spec.add_development_dependency 'ox'

  # For more information and examples about making a new gem, checkout our
  # guide at: https://bundler.io/guides/creating_gem.html
end
