# frozen_string_literal: true

require 'time'
require_relative 'base'
require_relative '../version'
require_relative '../rules/status_map'
require_relative '../rules/error_map'
require_relative '../rules/field_map'
require_relative '../rules/units_detection'
require_relative '../rules/overrides'

module Integrate
  module Generator
    # Renders the provider service Ruby file (`<provider>_service.rb`) from
    # the parsed spec + mapping rules. All logic-heavy pieces are delegated
    # to partial templates under templates/partials/ — see the main
    # `service.rb.erb` for the wiring.
    class Service < Base
      DEFAULT_PROVIDER_ERROR_CODES = %w[
        validation_error
        insufficient_balance
        recipient_not_found
        bank_unavailable
        amount_limit_exceeded
        rate_limit_exceeded
        internal_error
        unauthorized
        not_found
        invalid_status
      ].freeze

      def initialize(spec, status_map: nil, error_map: nil, field_map: nil, report: nil, overrides: nil, provenance: nil)
        super()
        @spec = spec
        @report = report
        @status_map = status_map || Integrate::Rules::StatusMap.new(report: report)
        @error_map  = error_map  || Integrate::Rules::ErrorMap.new(report: report)
        @field_map  = field_map  || Integrate::Rules::FieldMap.new(report: report)
        @overrides  = overrides || Integrate::Rules::Overrides.empty
        @provenance = provenance || {}
      end

      attr_reader :overrides

      # @return [String] rendered Ruby source
      def call
        validate_spec!
        emit_credentials_access_ambiguous!

        amount = locate_amount_field

        locals = {
          info: @spec.info,
          base_url: base_url,
          env_key: env_key,
          status_map_pairs: status_map_pairs,
          error_map_pairs: error_map_pairs,
          provider_error_map_pairs: provider_error_map_pairs,
          provider_error_map_defined: provider_error_map_pairs.any?,
          endpoints_by_role: endpoints_by_role,
          webhook: @spec.webhooks.first,
          amount_field: amount,
          auth: @spec.auth,
          payload_fields: payload_fields_for_create(amount),
          has_idempotency: create_has_idempotency?,
          overrides: @overrides,
          # Provenance stamps for the file header:
          generator_version: @provenance[:generator_version] || Integrate::VERSION,
          generated_at:      @provenance[:generated_at]      || Time.now.utc.iso8601,
          spec_path:         @provenance[:spec_path]         || '<unknown>',
          spec_sha256:       @provenance[:spec_sha256]       || '<unknown>',
          rules_path:        @provenance[:rules_path],
          rules_sha256:      @provenance[:rules_sha256]
        }
        render('service.rb.erb', locals)
      end

      # ---- Helpers callable from partials ------------------------------------

      # Maps a webhook signature algorithm symbol to the OpenSSL digest name.
      # Unknown/unresolvable algo → fallback to SHA256 with a warning so the
      # user sees it in the UNSUPPORTED.md report (or on stderr in CLI mode).
      def digest_name_for(algo)
        case algo.to_sym
        when :hmac_sha256, :hmac_sha1, :hmac_sha512, :timestamped_hmac_sha256
          algo.to_s.upcase.sub('HMAC_', '').sub('TIMESTAMPED_', '')
        else
          warn_signature_algo_unknown!(algo)
          'SHA256'
        end
      end

      # Heuristics for Stripe-style `t=<ts>,v1=<hex>` signature format:
      #   1. Header name ends in `-Sig` (Stripe/PayCloud convention) — as
      #      opposed to `-Signature` (NovaPay convention, plain hex).
      #   2. Description mentions `stripe` or `timestamp`.
      def stripe_format_signature?(webhook)
        return false unless webhook

        header = webhook.signature_header.to_s
        return true if header.match?(/-sig\z/i) && !header.match?(/-signature\z/i)

        # Only the header-name heuristic here; description hints are covered
        # by the explicit `overrides.signature.format` primitive.
        false
      end

      private

      def warn_signature_algo_unknown!(algo)
        return if @signature_algo_warned

        @signature_algo_warned = true
        msg = "signature algorithm #{algo.inspect} — defaulting to SHA256; " \
              'override via `overrides.signature.algo` if incorrect.'
        if @report.respond_to?(:warning)
          @report.warning(:signature_algo, msg)
        else
          warn "[integrate] #{msg}"
        end
      end


      def validate_spec!
        return if endpoints_by_role[:create]&.any?

        raise Integrate::Errors::SpecInvalid,
              'No POST endpoint suitable for create_request — expected an ' \
              'endpoint classified with role :create.'
      end

      def base_url
        @spec.servers.first&.url || 'https://api.example.com'
      end

      def env_key
        "#{@spec.info.provider_slug.upcase}_BASE_URL"
      end

      def status_map_pairs
        values = provider_status_values
        base = @status_map.build_map(values)
        # User overrides win and can extend the map with keys not in the enum.
        base.merge(@overrides.status_map).to_a
      end

      def provider_status_values
        endpoints_with_status_enum.flat_map { |ep| status_enum_of(ep) }.uniq
      end

      def endpoints_with_status_enum
        @spec.endpoints.select do |ep|
          %i[status callback create cancel].include?(ep.role)
        end
      end

      def status_enum_of(endpoint)
        (endpoint.responses.values + [endpoint.request_body].compact).flat_map do |body|
          next [] unless body.respond_to?(:schema) && body.schema

          field = body.schema.properties['status']
          field&.enum || []
        end
      end

      def error_map_pairs
        codes = declared_http_codes.select { |c| (400..599).cover?(c) }
        @error_map.build_http_map(codes).to_a
      end

      def declared_http_codes
        @spec.endpoints.flat_map { |ep| ep.responses.keys }.uniq.map(&:to_i).sort
      end

      def provider_error_map_pairs
        base = @error_map.build_provider_map(provider_error_codes)
        base.merge(@overrides.error_map).to_a
      end

      def provider_error_codes
        (declared_provider_error_codes + DEFAULT_PROVIDER_ERROR_CODES).uniq
      end

      def declared_provider_error_codes
        codes = []
        error_schema = @spec.schemas.values.find do |schema|
          schema&.properties&.dig('code')&.enum
        end
        codes.concat(error_schema.properties['code'].enum) if error_schema

        @spec.endpoints.each do |ep|
          ep.responses.each_value do |resp|
            resp.examples.each do |ex|
              value = ex.value
              next unless value.is_a?(Hash)

              code = value.dig('error', 'code')
              codes << code if code
            end
          end
        end
        codes.map(&:to_s).uniq
      end

      def endpoints_by_role
        @spec.endpoints.group_by(&:role)
      end

      def locate_amount_field
        endpoint = @spec.endpoints.find { |ep| ep.role == :create && ep.request_body }
        return nil unless endpoint

        schema = endpoint.request_body.schema
        return nil unless schema&.properties

        field = schema.properties['amount']
        return nil unless field

        units =
          if @overrides.amount_unit
            @overrides.amount_unit
          else
            detected = Integrate::Rules::UnitsDetection.detect(field, report: @report)
            emit_units_ambiguous!(field, detected) if detected != :unknown
            detected
          end
        field.with(units: units)
      end

      def emit_units_ambiguous!(field, detected)
        return unless @report

        desc = field.description.to_s.strip
        source =
          if desc.empty?
            "heuristic: type=#{field.type}, minimum=#{field.minimum.inspect}"
          else
            %(description: "#{desc}" at properties.#{field.name})
          end
        alt = detected == :minor ? 'major' : 'minor'
        @report.ambiguous.add(
          category:      :units,
          subject:       field.name,
          inferred:      detected,
          source:        source,
          override_yaml: "overrides:\n  amount_unit: #{detected}    # or `#{alt}`\n",
          spec_path:     "properties.#{field.name}.description"
        )
      end

      def emit_credentials_access_ambiguous!
        return unless @report
        return unless @overrides.credentials_access.nil?

        @report.ambiguous.add(
          category:      :credentials_access,
          subject:       'credentials',
          inferred:      :hash,
          source:        'not derivable from OpenAPI (host-side storage)',
          override_yaml: "overrides:\n  credentials_access: hash    # or method (credentials.api_key)\n"
        )
      end

      def create_has_idempotency?
        endpoint = @spec.endpoints.find { |ep| ep.role == :create }
        return false unless endpoint

        endpoint.header_params.any? { |h| h.name.to_s.match?(/idempotency/i) }
      end

      # Returns [[field_name, ruby_expr, comment_or_nil], ...] describing the
      # body of build_payout_payload. Currently supports a flat top-level with
      # optional nested `recipient` object.
      def payload_fields_for_create(amount_field)
        endpoint = @spec.endpoints.find { |ep| ep.role == :create }
        return [] unless endpoint&.request_body&.schema&.properties

        rows = []
        endpoint.request_body.schema.properties.each do |name, field|
          field = field.with(units: amount_field&.units) if name == 'amount' && amount_field
          expr, comment = expression_for(name, field)
          rows << [name, expr, comment]
        end
        rows
      end

      def expression_for(name, field)
        role = @field_map.classify(field)

        case role
        when :amount
          if field.units == :minor
            ['(operation.amount * 100).to_i', 'amount in minor units (kopecks)']
          else
            ['operation.amount', nil]
          end
        when :currency
          if field.enum && field.enum.length == 1
            ["'#{field.enum.first}'", nil]
          else
            ["operation.currency || '#{field.example || 'RUB'}'", nil]
          end
        when :external_id
          ['operation.id', nil]
        else
          nested_expression_for(name, field, role)
        end
      end

      def nested_expression_for(name, field, _role)
        return recipient_hash_expression(field) if name == 'recipient' && field.type == 'object'

        # Wrapped in `begin/rescue` because inline `X rescue nil` is a syntax error
        # inside a Hash literal in Ruby 3.x — parser treats `rescue` as a modifier
        # binding to the outermost expression, not to `X`.
        ["(begin; operation.public_send(:#{name}); rescue StandardError; nil; end)",
         "TODO: no mapping for '#{name}' — set manually or add rule to config/field_rules.yaml"]
      end

      def recipient_hash_expression(field)
        # Build a literal Hash expression that mirrors payout_requisite.dig(...)
        # for each nested property, keyed under 'sbp'. `card`/`bank` types are
        # left to `overrides.required_if` in the private partial.
        props = field.type == 'object' ? recipient_props(field) : {}
        return ['operation.payout_requisite', nil] if props.empty?

        rendered = filtered_recipient_props(props).map do |prop_name, sub_field|
          [prop_name, recipient_prop_expression(prop_name, sub_field)]
        end
        return ['operation.payout_requisite', nil] if rendered.empty?

        lines = ["{\n"]
        rendered.each_with_index do |(prop_name, value), idx|
          suffix = idx == rendered.length - 1 ? '' : ','
          lines << "          #{prop_name}: #{value}#{suffix}\n"
        end
        lines << '        }'
        [lines.join, nil]
      end

      # Keep only the SBP-family properties (skip card-only fields) so the
      # generated payload matches the reference shape for SBP payouts.
      def filtered_recipient_props(props)
        sbp_roles = %i[recipient_type recipient_phone recipient_bank_code recipient_bank_name]
        props.select { |_name, sub_field| sbp_roles.include?(@field_map.classify(sub_field)) }
      end

      def recipient_prop_expression(prop_name, sub_field)
        case @field_map.classify(sub_field)
        when :recipient_type
          enum = Array(sub_field.enum)
          enum.length == 1 ? "'#{enum.first}'" : "'sbp'"
        when :recipient_phone
          "operation.payout_requisite.dig('sbp', 'phone')"
        when :recipient_bank_code
          "operation.payout_requisite.dig('sbp', 'bank_code')"
        when :recipient_bank_name
          "operation.payout_requisite.dig('sbp', 'bank_name')"
        when :recipient_card_number
          "operation.payout_requisite.dig('card', 'number')"
        when :recipient_account
          "operation.payout_requisite.dig('bank', 'account')"
        else
          "operation.payout_requisite.dig('sbp', '#{prop_name}')"
        end
      end

      def recipient_props(field)
        # Field.properties isn't set directly; the actual nested schema lives in
        # the parent Schema. Walk the spec's schemas for a matching object.
        @spec.schemas.each_value do |schema|
          next unless schema&.type == 'object' && schema.properties

          match = schema.properties.keys.sort
          candidate_keys = %w[type phone bank_code]
          return schema.properties if candidate_keys.all? { |k| match.include?(k) }
        end
        {}
      end
    end
  end
end
