# frozen_string_literal: true

source 'https://rubygems.org'

# Runtime dependencies for the generator tool itself.
# Faraday is intentionally NOT here — it is a runtime dep of the *generated*
# service (Provider::NovapayService), not of the generator. Users add it in
# their host Rails app.
gem 'openapi3_parser', '~> 0.10'
gem 'thor',            '~> 1.5'

group :development, :test do
  gem 'rspec', '~> 3.13'
  # rubocop is intentionally omitted from CP1 because its transitive dep
  # `prism` requires ruby-dev headers to compile a C extension, and this
  # environment does not ship them. Style checks will be added in CP3
  # after the ruby-dev package is available in the target env.
end
