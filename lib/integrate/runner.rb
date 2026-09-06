# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'digest'
require 'time'

require_relative 'version'
require_relative 'parser/openapi'
require_relative 'generator/service'
require_relative 'generator/doc'
require_relative 'generator/fixtures'
require_relative 'generator/unsupported'
require_relative 'report'
require_relative 'rules/status_map'
require_relative 'rules/error_map'
require_relative 'rules/field_map'
require_relative 'rules/overrides'

module Integrate
  # Wires everything together: parse → apply rules → render → write files →
  # print the log line-by-line via Report. Log format matches the task
  # specification (see /tmp/docx_extract/text.txt lines 167-180).
  class Runner
    DEFAULT_OUTPUT_ROOT = './output'

    def initialize(spec:, provider:, lang: 'ruby', output: nil, rules: nil, report: nil)
      @spec_path = spec
      @provider  = provider
      @lang      = lang
      # Default output goes to ./output/<provider>/ so multiple providers
      # don't collide, and each generated directory carries its own identity.
      @output    = output || File.join(DEFAULT_OUTPUT_ROOT, provider.to_s)
      @rules     = rules
      @report    = report || Report.new
      @overrides = Integrate::Rules::Overrides.from_rules_file(rules)
      @started_at = Time.now.utc
    end

    def call
      report.log('Parsing spec...')
      spec = Integrate::Parser::OpenApi.new(@spec_path).parse

      log_endpoint_summary(spec)
      log_auth(spec.auth)
      log_webhook(spec.webhooks.first) if spec.webhooks.any?

      # Emit spec-level Unsupported/Ambiguous entries now that we have the spec.
      collect_spec_level_reports(spec)

      warn_overwrite_if_dirty
      FileUtils.mkdir_p(@output)
      files = write_artifacts(spec)

      maybe_write_unsupported(spec, files)
      files[:meta] = write_meta(spec)
      log_unsupported_summary
      log_output(files)
      files
    end

    private

    attr_reader :report

    def log_endpoint_summary(spec)
      list = spec.endpoints.map { |ep| "#{ep.method.upcase} #{ep.path}" }.join(', ')
      report.log("Found #{spec.endpoints.size} endpoints: #{list}")
    end

    def log_auth(auth)
      return report.log('Auth: none (WARNING: no security scheme detected)') unless auth

      loc = auth.location ? "#{auth.location}: #{auth.header_or_param_name}" : auth.type
      report.log("Auth: #{auth.scheme_name} (#{loc})")
    end

    def log_webhook(webhook)
      return unless webhook

      report.log("Webhook signature: #{webhook.signature_header} (#{webhook.signature_algo})")
    end

    def log_unsupported_summary
      unsupported_count = @report.unsupported.to_h.values.sum(&:size)
      ambiguous_count   = @report.ambiguous.to_h.values.sum(&:size)

      if unsupported_count.zero? && ambiguous_count.zero?
        report.log('UNSUPPORTED: none')
      else
        parts = []
        parts << "#{unsupported_count} unsupported" if unsupported_count.positive?
        parts << "#{ambiguous_count} ambiguous"     if ambiguous_count.positive?
        report.log("UNSUPPORTED: #{parts.join(', ')} → #{@output}/UNSUPPORTED.md")
      end

      buckets = report.buckets
      return if buckets.empty? || buckets.values.all?(&:empty?)

      buckets.each do |kind, entries|
        next if entries.empty?

        report.log("Warning: #{entries.size} unmapped #{kind}(s): #{summarize(entries)}")
      end
    end

    def summarize(entries)
      entries.first(5).map { |e| e.is_a?(Hash) ? e.inspect : e.to_s }.join(', ')
    end

    def write_artifacts(spec)
      status_map = build_status_map
      error_map  = build_error_map
      field_map  = build_field_map
      files = {}

      report.log('Generating service...')
      files[:service] = write(
        service_path(spec),
        Generator::Service.new(
          spec,
          status_map: status_map,
          error_map: error_map,
          field_map: field_map,
          report: @report,
          overrides: @overrides,
          provenance: provenance
        ).call
      )

      report.log('Generating integration guide...')
      files[:doc] = write(
        doc_path(spec),
        Generator::Doc.new(
          spec,
          status_map: status_map,
          error_map: error_map,
          report: @report,
          overrides: @overrides
        ).call
      )

      report.log('Generating test fixtures...')
      files[:fixtures] = write(
        fixtures_path(spec),
        Generator::Fixtures.new(spec, report: @report).call
      )

      files
    end

    def maybe_write_unsupported(spec, files)
      return unless @report.any?

      path = unsupported_path(spec)
      File.write(path, Generator::Unsupported.new(@report, spec: spec, output_dir: @output).call)
      files[:unsupported] = path
    end

    # Collect Ambiguous entries that depend on the parsed spec but not on
    # generator internals (webhook signature encoding/body/format, algo when
    # inferred). Called from #call once the spec is available.
    def collect_spec_level_reports(spec)
      webhook = spec.webhooks.first
      return unless webhook

      header = webhook.signature_header.to_s
      spec_path = signature_spec_path(spec, webhook)

      # signature_algo — only Ambiguous if not overridden.
      if @overrides.signature_algo.nil? && webhook.signature_algo && webhook.signature_algo != :unknown
        source = webhook_algo_source(webhook)
        algo   = webhook.signature_algo
        alts   = %i[hmac_sha256 hmac_sha512 hmac_sha1].reject { |a| a == algo }
        @report.ambiguous.add(
          category:      :signature_algo,
          subject:       header,
          inferred:      algo,
          source:        source,
          override_yaml: "overrides:\n  signature:\n    algo: #{algo}    # or #{alts.join(', ')}\n",
          spec_path:     spec_path
        )
      end

      if @overrides.signature_encoding.nil?
        @report.ambiguous.add(
          category:      :signature_encoding,
          subject:       header,
          inferred:      :hex,
          source:        'default (no info in spec)',
          override_yaml: "overrides:\n  signature:\n    encoding: hex    # or base64\n"
        )
      end

      if @overrides.signature_body.nil?
        @report.ambiguous.add(
          category:      :signature_body,
          subject:       header,
          inferred:      :raw,
          source:        'default (no info in spec)',
          override_yaml: "overrides:\n  signature:\n    body: raw    # or json\n"
        )
      end

      if @overrides.signature_format.nil?
        stripe_hint = header.match?(/-sig\z/i) && !header.match?(/-signature\z/i)
        inferred_format = stripe_hint ? :stripe : :plain
        alt = inferred_format == :stripe ? 'plain' : 'stripe'
        source = stripe_hint ? 'header format contains "t=<ts>,v1=<hex>" pattern' : 'default (no info in spec)'
        @report.ambiguous.add(
          category:      :signature_format,
          subject:       header,
          inferred:      inferred_format,
          source:        source,
          override_yaml: "overrides:\n  signature:\n    format: #{inferred_format}    # or #{alt}\n",
          spec_path:     stripe_hint ? spec_path : nil
        )
      end

      # WebhookSignature (Unsupported) — Stripe-style is best-effort in MVP.
      if @overrides.signature_format.nil? && header.match?(/-sig\z/i) && !header.match?(/-signature\z/i)
        @report.unsupported.add(
          :webhook_signature,
          header,
          "signature format `t=<ts>,v1=<hex>` (Stripe-style timestamped HMAC) — best-effort template",
          path: spec_path,
          hint: 'confirm via `overrides.signature.format: stripe`'
        )
      end
    end

    def webhook_algo_source(webhook)
      # Best-effort: derive a readable source from the algo. The parser sets
      # :hmac_sha256 as the default if no algorithm is mentioned, and matches
      # explicit sha256/sha512/sha1 substrings when present.
      case webhook.signature_algo
      when :hmac_sha512
        'description matches /sha512/i (webhook parameter description)'
      when :hmac_sha1
        'description matches /sha1/i (webhook parameter description)'
      when :hmac_sha256
        'description matches /sha256/i (webhook parameter description)'
      else
        'default (X-*-Signature convention, no algorithm in description)'
      end
    end

    def signature_spec_path(_spec, webhook)
      # Best-effort YAML path for the signature header parameter. The parser
      # doesn't currently retain the callback path, so we fall back to the
      # signature header name.
      "webhooks.#{webhook.signature_header}"
    end

    def provenance
      @provenance ||= {
        generator_version: Integrate::VERSION,
        generated_at:      @started_at.iso8601,
        spec_path:         @spec_path,
        spec_sha256:       sha256_of_file(@spec_path),
        rules_path:        @rules,
        rules_sha256:      (@rules && File.exist?(@rules) ? sha256_of_file(@rules) : nil)
      }
    end

    def build_status_map
      Integrate::Rules::StatusMap.new(@rules, report: @report, overrides: @overrides)
    end

    def build_error_map
      Integrate::Rules::ErrorMap.new(nil, report: @report)
    end

    def build_field_map
      Integrate::Rules::FieldMap.new(nil, report: @report)
    end

    # Files live under output/<provider>/ — the directory itself carries the
    # identity, so the filenames stay short and generic.
    def service_path(spec)
      File.join(@output, "#{spec.info.provider_slug}_service.rb")
    end

    def doc_path(_spec)
      File.join(@output, 'INTEGRATION.md')
    end

    def fixtures_path(_spec)
      File.join(@output, 'fixtures.json')
    end

    def unsupported_path(_spec)
      File.join(@output, 'UNSUPPORTED.md')
    end

    def write(path, content)
      File.write(path, content)
      path
    end

    # If the output directory already contains a previous generation, print a
    # WARN line so the user knows we're overwriting. Doesn't block — but
    # signals the identity conflict for logs/CI.
    def warn_overwrite_if_dirty
      return unless File.directory?(@output)

      existing = Dir.glob(File.join(@output, '*')).reject { |p| File.basename(p) == '.gitkeep' }
      return if existing.empty?

      prev_meta = File.join(@output, '.integrate.meta.json')
      identity =
        if File.exist?(prev_meta)
          begin
            m = JSON.parse(File.read(prev_meta))
            " (previous: #{m['provider']}, generated_at=#{m['generated_at']}, spec_sha256=#{m['spec_sha256'][0, 8]})"
          rescue StandardError
            ''
          end
        else
          ''
        end
      report.log("Warning: overwriting existing files in #{@output}#{identity}")
    end

    # Write .integrate.meta.json with all identity markers so a reviewer can
    # tell at a glance: from which spec + which rules + which generator version
    # + when + what SHA. Placed inside the output dir alongside the artefacts.
    def write_meta(spec)
      path = File.join(@output, '.integrate.meta.json')
      meta = {
        'generator'       => 'integrate',
        'generator_version' => Integrate::VERSION,
        'provider'        => @provider,
        'lang'            => @lang,
        'generated_at'    => @started_at.iso8601,
        'spec_path'       => @spec_path,
        'spec_sha256'     => sha256_of_file(@spec_path),
        'rules_path'      => @rules,
        'rules_sha256'    => (@rules && File.exist?(@rules) ? sha256_of_file(@rules) : nil),
        'ruby_version'    => RUBY_VERSION,
        'endpoints_count' => spec.endpoints.size,
        'has_webhook'     => spec.webhooks.any?,
        'unsupported_count' => @report.unsupported.to_h.values.sum(&:size),
        'ambiguous_count'   => @report.ambiguous.to_h.values.sum(&:size)
      }
      File.write(path, JSON.pretty_generate(meta) + "\n")
      path
    end

    def sha256_of_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def log_output(files)
      report.log('')
      report.log('Output:')
      files.each_value { |path| report.log("  #{relative(path)}") }
    end

    def relative(path)
      path.start_with?(Dir.pwd) ? ".#{path.delete_prefix(Dir.pwd)}" : path
    end
  end
end
