# frozen_string_literal: true

require 'erb'

module Integrate
  module Generator
    # Minimal ERB rendering harness shared by all generators. Supports both
    # top-level templates in templates/ and reusable partials in
    # templates/partials/ (leading underscore + .rb.erb suffix — Rails-style).
    class Base
      TEMPLATES_DIR = File.expand_path('../../../templates', __dir__)
      PARTIALS_DIR  = File.join(TEMPLATES_DIR, 'partials')

      # @param template [String] file name inside templates/
      # @param locals   [Hash<Symbol, Object>]
      def render(template, locals = {})
        path = File.join(TEMPLATES_DIR, template)
        raise Integrate::Errors::TemplateError, "Template not found: #{path}" unless File.file?(path)

        run_erb(path, locals)
      rescue Integrate::Errors::TemplateError
        raise
      rescue StandardError => e
        raise Integrate::Errors::TemplateError, "Template #{template} failed: #{e.class}: #{e.message}"
      end

      # Render a partial from templates/partials/. `name` is the bare partial
      # name (e.g. 'header') — the underscore prefix and the .rb.erb suffix
      # are added automatically. Partials receive the same rendering pipeline
      # as top-level templates and can themselves call render_partial.
      #
      # @param name   [String, Symbol]
      # @param locals [Hash<Symbol, Object>]
      # @return [String]
      def render_partial(name, locals = {})
        file = "_#{name}.rb.erb"
        path = File.join(PARTIALS_DIR, file)
        raise Integrate::Errors::TemplateError, "Partial not found: #{path}" unless File.file?(path)

        run_erb(path, locals)
      rescue Integrate::Errors::TemplateError
        raise
      rescue StandardError => e
        raise Integrate::Errors::TemplateError, "Partial #{name} failed: #{e.class}: #{e.message}"
      end

      private

      def run_erb(path, locals)
        erb = ERB.new(File.read(path), trim_mode: '-')
        erb.filename = path
        erb.result(build_binding(locals))
      end

      def build_binding(locals)
        bind = binding
        # `self` inside the ERB template resolves to this generator instance,
        # so partials can be nested naturally via `render_partial('...')`.
        locals.each { |k, v| bind.local_variable_set(k, v) }
        bind
      end
    end
  end
end
