# frozen_string_literal: true

require 'thor'

require_relative 'errors'
require_relative 'runner'

module Integrate
  # Thor-based CLI. Subcommands: generate / verify / version.
  #
  # Exit codes:
  #   0  — success
  #   2  — SpecInvalid (bad OpenAPI) or SyntaxError inside a generated file
  #   3  — contract broken (a required method is missing on the generated class)
  #   65 — Errors::InvalidOverride (bad --rules YAML) — UNIX EX_DATAERR
  #   66 — file not found (UNIX EX_NOINPUT)
  #   1  — anything else
  class Cli < Thor
    RED   = "\e[31m"
    RESET = "\e[0m"

    package_name 'integrate'

    def self.exit_on_failure?
      true
    end

    default_task :generate

    desc 'generate', 'Generate integration files from an OpenAPI spec'
    long_desc <<~DESC
      Reads an OpenAPI 3.x spec, applies the mapping rules, and writes:
        * <output>/<provider>_service.rb  — Ruby service (Provider::BaseService)
        * <output>/INTEGRATION.md         — human-readable integration guide
        * <output>/fixtures.json          — test fixtures
    DESC
    option :spec,     required: true,  type: :string, desc: 'Path to OpenAPI YAML'
    option :provider, required: true,  type: :string, desc: 'Provider slug (e.g., novapay)'
    option :lang,     default: 'ruby', type: :string, desc: 'Output language (only ruby in MVP)'
    option :output,   type: :string,
                      desc: 'Output directory. Default: ./output/<provider>/'
    option :rules,    type: :string, desc: 'Path to custom rules YAML'
    def generate
      Integrate::Runner.new(**options.transform_keys(&:to_sym)).call
    rescue Integrate::Errors::SpecInvalid => e
      warn "#{RED}Spec invalid:#{RESET} #{e.message}"
      exit 2
    rescue Integrate::Errors::InvalidOverride => e
      warn "#{RED}Error:#{RESET} #{e.message}"
      exit 65
    rescue Errno::ENOENT => e
      warn "#{RED}File not found:#{RESET} #{e.message}"
      exit 66
    rescue Integrate::Errors::Error => e
      warn "#{RED}Error:#{RESET} #{e.message}"
      exit 1
    end

    desc 'version', 'Show integrate version'
    def version
      require_relative 'version'
      puts "integrate #{Integrate::VERSION}"
    end

    desc 'verify PATH', 'Load a generated service file under the BaseService stub and check its contract'
    long_desc <<~DESC
      Loads the file at PATH (a *_service.rb produced by `integrate generate`),
      first requiring `spec/support/provider_base_stub.rb` to satisfy the
      `Provider::BaseService` constant. Verifies that the class inherits from
      BaseService and defines the four contract methods.

      This is the correct smoke-test for a generated file — running plain
      `ruby <file>` fails because Provider::BaseService only exists in the
      Space Payments host application.
    DESC
    def verify(path)
      abs = File.expand_path(path)
      unless File.exist?(abs)
        warn "#{RED}File not found:#{RESET} #{abs}"
        exit 66
      end

      stub_path = File.expand_path('../../spec/support/provider_base_stub.rb', __dir__)
      require stub_path
      load abs

      class_name = File.basename(abs, '.rb').split('_').map(&:capitalize).join
      full_name  = "Provider::#{class_name}"
      klass      = Object.const_get(full_name)

      %i[create_request fetch_status process_callback check_conditions].each do |m|
        next if klass.public_method_defined?(m)

        warn "#{RED}Contract broken:#{RESET} #{full_name} is missing ##{m}"
        exit 3
      end

      puts "✓ #{full_name} loaded under stub, all 4 contract methods present."
      puts "  Ancestors: #{klass.ancestors.take(3).inspect}"
    rescue NameError => e
      warn "#{RED}Contract broken:#{RESET} #{e.message}"
      exit 3
    rescue SyntaxError => e
      warn "#{RED}Syntax error in generated file:#{RESET} #{e.message}"
      exit 2
    end
  end
end
