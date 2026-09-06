# frozen_string_literal: true

require_relative 'base'
require_relative '../rules/status_map'
require_relative '../rules/error_map'
require_relative '../rules/overrides'

module Integrate
  module Generator
    # Renders `output/INTEGRATION.md` — a human-readable integration guide
    # aligned with the task specification (see /tmp/docx_extract/text.txt
    # lines 98-135) plus a few extra sections (env vars, usage snippet).
    class Doc < Base
      # Default ProviderGateway payload for NovaPay-style SBP payouts. Custom
      # providers can override via --gateway-config in a future CP.
      DEFAULT_GATEWAY = { 'external_method' => 'sbp_payout', 'gateway' => 'RUB_SBP_WITHDRAW' }.freeze

      # Ops action per HTTP status — used to populate the "error handling" table.
      HTTP_ACTIONS = {
        400 => 'reject operation',
        401 => 'alert ops, block provider',
        402 => 'retry later',
        403 => 'alert ops, block provider',
        404 => 'log and mark unknown',
        409 => 'treat as success on create (duplicate)',
        422 => 'reject operation',
        429 => 'retry with backoff (see Retry-After)',
        500 => 'retry with backoff, alert ops',
        502 => 'retry with backoff, alert ops',
        503 => 'retry later',
        504 => 'retry with backoff, alert ops'
      }.freeze

      def initialize(spec, status_map: nil, error_map: nil, report: nil, overrides: nil)
        super()
        @spec = spec
        @report = report
        @status_map = status_map || Integrate::Rules::StatusMap.new(report: report)
        @error_map  = error_map  || Integrate::Rules::ErrorMap.new(report: report)
        @overrides  = overrides || Integrate::Rules::Overrides.empty
      end

      # @return [String] rendered Markdown
      def call
        render('INTEGRATION.md.erb', locals)
      end

      # ---- Helpers callable from the template --------------------------------

      def method_table_row(endpoint)
        purpose = endpoint.summary || endpoint.description&.split("\n")&.first || endpoint.operation_id
        idem = endpoint.header_params.any? { |h| h.name.to_s.match?(/idempotency/i) } ? 'Idempotency-Key header' : '-'
        "| #{method_name_for(endpoint)} | #{endpoint.method.upcase} #{endpoint.path} | #{purpose.to_s.strip} | #{idem} |"
      end

      def method_name_for(endpoint)
        case endpoint.role
        when :create   then 'create_request'
        when :status   then 'fetch_status'
        when :cancel   then 'cancel_request'
        when :callback then 'process_callback'
        when :balance  then 'fetch_balance'
        else endpoint.operation_id
        end
      end

      def http_action_for(code)
        HTTP_ACTIONS[code.to_i] || 'log and inspect'
      end

      private

      def locals
        {
          info: @spec.info,
          auth: @spec.auth,
          servers: @spec.servers,
          endpoints: @spec.endpoints,
          webhook: @spec.webhooks.first,
          status_pairs: status_pairs,
          http_error_rows: http_error_rows,
          provider_error_rows: provider_error_rows,
          env_key: "#{@spec.info.provider_slug.upcase}_BASE_URL",
          api_key_env: "#{@spec.info.provider_slug.upcase}_API_KEY",
          callback_secret_env: "#{@spec.info.provider_slug.upcase}_CALLBACK_SECRET",
          gateway_config: DEFAULT_GATEWAY,
          example_endpoint: @spec.endpoints.find { |ep| ep.role == :create },
          assumption_rows: assumption_rows
        }
      end

      # Build the `## Assumptions` table rows from report.ambiguous. Returns
      # an empty array when there is nothing to declare (or no report).
      def assumption_rows
        return [] unless @report

        rows = []
        @report.ambiguous.to_h.each do |category, entries|
          entries.each do |entry|
            rows << {
              assumption: assumption_label(category, entry[:subject]),
              inferred:   entry[:inferred].to_s,
              override:   override_hint_for(category)
            }
          end
        end
        rows
      end

      def assumption_label(category, subject)
        case category
        when :units               then 'amount unit'
        when :signature_algo      then "signature algo (#{subject})"
        when :signature_encoding  then "signature encoding (#{subject})"
        when :signature_body      then "signature body (#{subject})"
        when :signature_format    then "signature format (#{subject})"
        when :required_if         then "required_if (#{subject})"
        when :credentials_access  then 'credentials access'
        when :status_map_fallback then "status map (#{subject})"
        when :error_map_fallback  then "error map (#{subject})"
        else category.to_s
        end
      end

      def override_hint_for(category)
        case category
        when :units               then '`overrides.amount_unit: minor|major`'
        when :signature_algo      then '`overrides.signature.algo: hmac_sha256|hmac_sha512|hmac_sha1`'
        when :signature_encoding  then '`overrides.signature.encoding: hex|base64`'
        when :signature_body      then '`overrides.signature.body: raw|json`'
        when :signature_format    then '`overrides.signature.format: plain|stripe`'
        when :required_if         then '`overrides.required_if: [{ field: <name>, when: { k: v } }]`'
        when :credentials_access  then '`overrides.credentials_access: hash|method`'
        when :status_map_fallback then '`overrides.status_map: { <provider>: <internal> }`'
        when :error_map_fallback  then '`overrides.error_map: { <code>: <internal_key> }`'
        else '`overrides:` (see docs/analysis/overrides_spec.md)'
        end
      end

      def status_pairs
        values = @spec.endpoints.flat_map do |ep|
          next [] unless %i[status callback create cancel].include?(ep.role)

          bodies = ep.responses.values + [ep.request_body].compact
          bodies.flat_map do |body|
            next [] unless body.respond_to?(:schema) && body.schema

            body.schema.properties['status']&.enum || []
          end
        end.uniq
        @status_map.build_map(values).merge(@overrides.status_map).to_a
      end

      def http_error_rows
        codes = @spec.endpoints.flat_map { |ep| ep.responses.keys }.uniq.map(&:to_i)
                     .select { |c| (400..599).cover?(c) }.sort
        map = @error_map.build_http_map(codes)
        codes.map do |code|
          key = map[code] || 'unknown'
          "| #{code} | #{key} | #{http_action_for(code)} |"
        end
      end

      def provider_error_rows
        codes = []
        @spec.schemas.each_value do |schema|
          next unless schema&.properties&.dig('code')&.enum

          codes.concat(schema.properties['code'].enum)
        end
        codes = codes.uniq
        provider_map = @error_map.build_provider_map(codes).merge(@overrides.error_map)
        (codes + @overrides.error_map.keys).uniq.map do |code|
          "| #{code} | #{provider_map[code] || code} |"
        end
      end
    end
  end
end
