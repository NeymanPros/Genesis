# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'integrate/version'

Gem::Specification.new do |spec|
  spec.name          = 'integrate'
  spec.version       = Integrate::VERSION
  spec.authors       = ['Space Payments Hackathon Team']
  spec.email         = ['integration@example.com']

  spec.summary       = 'Deterministic generator of payment-provider integrations from OpenAPI specs.'
  spec.description   = <<~DESC
    Reads an OpenAPI 3 spec of a payment provider and generates a Ruby service
    class that conforms to the Provider::BaseService contract, plus an
    integration guide (Markdown) and test fixtures (JSON). Deterministic —
    no LLM calls at runtime.
  DESC
  spec.homepage      = 'https://example.com/integrate'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.files = Dir[
    'lib/**/*.rb',
    'templates/**/*',
    'config/**/*.yaml',
    'bin/*',
    'README.md',
    'LICENSE*'
  ]
  spec.bindir        = 'bin'
  spec.executables   = ['integrate']
  spec.require_paths = ['lib']

  spec.add_dependency 'openapi3_parser', '~> 0.10'
  spec.add_dependency 'thor', '~> 1.5'
end
