# frozen_string_literal: true

require 'yaml'

module Integrate
  module Rules
    # Maps provider status strings ('pending', 'completed', ...) to internal
    # Space Payments statuses ('in_progress', 'approved', 'rejected').
    #
    # Rules are read from config/status_rules.yaml as an ordered list of
    # `{ match: <regex>, to: <internal> }` pairs plus a `fallback`. First
    # match wins.
    class StatusMap
      INTERNAL = %w[in_progress approved rejected unknown].freeze

      # Canonical Space Payments status mapping — the source of truth when a
      # provider spec doesn't include an explicit status enum or table.
      CANONICAL_FALLBACK = {
        'pending'    => 'in_progress',
        'processing' => 'in_progress',
        'completed'  => 'approved',
        'failed'     => 'rejected',
        'cancelled'  => 'rejected'
      }.freeze

      def initialize(rules_path = nil, report: nil, overrides: nil)
        @rules_path = rules_path || default_path
        @report     = report
        @overrides  = overrides
        @unmatched  = []
        load_rules
      end

      # @param provider_status [String]
      # @return [String] one of INTERNAL
      def apply(provider_status)
        raw = provider_status.to_s.downcase.strip
        rule = @rules.find { |r| r[:regex].match?(raw) }
        return rule[:to] if rule

        # Second chance — canonical Space Payments fallback (best-effort). If it
        # matches, emit an Ambiguous record so the user can pin it explicitly.
        canon = CANONICAL_FALLBACK[raw]
        if canon
          emit_canonical_ambiguous!(provider_status.to_s, canon)
          return canon
        end

        @unmatched << provider_status.to_s
        @report&.unmapped(:status, provider_status.to_s)
        @fallback
      end

      # Given a list of provider values (e.g. from an enum), build the hash
      # STATUS_MAP that is embedded in the generated service. Values that map
      # to `unknown` are excluded — see mapping_rules.md §1.
      def build_map(provider_values)
        provider_values.each_with_object({}) do |value, acc|
          mapped = apply(value)
          acc[value.to_s] = mapped unless mapped == 'unknown'
        end
      end

      def unmatched
        @unmatched.dup
      end

      def emit_canonical_ambiguous!(raw, canon)
        return unless @report && @report.respond_to?(:ambiguous)
        # If the user explicitly pinned this status via overrides.status_map,
        # the canonical fallback is no longer ambiguous — skip the entry.
        return if @overrides&.status_map&.key?(raw)

        @report.ambiguous.add(
          category:      :status_map_fallback,
          subject:       raw,
          inferred:      canon,
          source:        'canonical Space Payments fallback (spec has no explicit rule)',
          override_yaml: "overrides:\n  status_map:\n    #{raw}: #{canon}\n"
        )
      end


      def default_path
        File.expand_path('../../../config/status_rules.yaml', __dir__)
      end

      def load_rules
        data = YAML.safe_load(File.read(@rules_path))
        @rules = Array(data['rules']).map do |rule|
          { regex: Regexp.new(rule.fetch('match'), Regexp::IGNORECASE), to: rule.fetch('to').to_s }
        end
        @fallback = (data['fallback'] || 'unknown').to_s
      end
    end
  end
end
