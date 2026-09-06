# frozen_string_literal: true

require 'yaml'

module Integrate
  module Rules
    # Three-level mapping of provider errors to internal keys:
    #   1) RFC 7807 `type` URI last segment (application/problem+json) wins.
    #   2) Provider-specific `error.code` (NovaPay-style) second.
    #   3) HTTP status is used as fallback.
    #   4) Global `fallback` (default 'unknown') otherwise.
    class ErrorMap
      def initialize(rules_path = nil, report: nil)
        @rules_path = rules_path || default_path
        @report     = report
        load_rules
      end

      # @param response [#status, #body] a response-like object with a Hash body.
      # @return [Hash]
      def apply(response)
        body = response.body.is_a?(Hash) ? response.body : {}

        provider_type = body['type']
        rule = match_provider_type_rule(provider_type)
        return rule if rule

        provider_code = body.dig('error', 'code')
        rule = match_provider_rule(provider_code)
        return rule if rule

        http_rule = @by_http_status[response.status.to_i]
        return http_rule if http_rule

        @report&.unmapped(:error, { code: provider_code, type: provider_type, http: response.status })
        @fallback
      end

      # Hash{String => String} for use as PROVIDER_TYPE_MAP (RFC 7807).
      # `type_uris` — array of full URI strings from spec, we key by last segment.
      def build_provider_type_map(type_uris)
        type_uris.each_with_object({}) do |uri, acc|
          slug = last_segment(uri)
          next unless slug

          rule = match_provider_type_rule(uri)
          acc[slug] = rule ? rule[:internal_key] : slug
        end
      end

      # Hash{Integer => String} for use as ERROR_MAP inside generated service.
      def build_http_map(http_codes)
        http_codes.each_with_object({}) do |code, acc|
          rule = @by_http_status[code.to_i]
          acc[code.to_i] = rule[:internal_key] if rule
        end
      end

      # Hash{String => String} for use as PROVIDER_ERROR_MAP inside generated
      # service. `provider_codes` is the enum of provider-side error codes.
      def build_provider_map(provider_codes)
        provider_codes.each_with_object({}) do |code, acc|
          rule = match_provider_rule(code)
          acc[code.to_s] = rule ? rule[:internal_key] : code.to_s
        end
      end

      private

      def default_path
        File.expand_path('../../../config/error_rules.yaml', __dir__)
      end

      def load_rules
        data = YAML.safe_load(File.read(@rules_path))
        @by_provider_type = Array(data['by_provider_type']).map { |r| compile_rule(r) }
        @by_provider = Array(data['by_provider_code']).map { |r| compile_rule(r) }
        @by_http_status = (data['by_http_status'] || {}).each_with_object({}) do |(code, rule), acc|
          acc[code.to_i] = { internal_key: rule.fetch('to').to_s, http_sym: rule.fetch('http_sym').to_sym }
        end
        fb = data['fallback'] || { 'to' => 'unknown', 'http_sym' => 'internal_server_error' }
        @fallback = { internal_key: fb['to'].to_s, http_sym: fb['http_sym'].to_sym }
      end

      def compile_rule(r)
        {
          regex: Regexp.new(r.fetch('match'), Regexp::IGNORECASE),
          internal_key: r.fetch('to').to_s,
          http_sym: r.fetch('http_sym').to_sym
        }
      end

      def match_provider_rule(code)
        return nil unless code

        norm = code.to_s.downcase.strip
        rule = @by_provider.find { |r| r[:regex].match?(norm) }
        rule ? { internal_key: rule[:internal_key], http_sym: rule[:http_sym] } : nil
      end

      def match_provider_type_rule(type_uri)
        return nil unless type_uri

        slug = last_segment(type_uri)
        return nil unless slug

        rule = @by_provider_type.find { |r| r[:regex].match?(slug) }
        rule ? { internal_key: rule[:internal_key], http_sym: rule[:http_sym] } : nil
      end

      def last_segment(uri)
        return nil unless uri.is_a?(String) && !uri.empty?

        # For URIs like "https://p.ex/problems/insufficient-funds" → "insufficient-funds".
        # For plain slugs already ("insufficient-funds") → itself.
        uri.split('/').last&.split('#')&.first&.downcase&.strip
      end
    end
  end
end
