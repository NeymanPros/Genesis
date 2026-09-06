# frozen_string_literal: true

module Integrate
  # Collects console-lines and diagnostics during a generator run.
  #
  # Three responsibilities:
  #   1. `puts` the step-by-step run log ("Parsing spec...", ...).
  #   2. Aggregate structured Unsupported entries (categories from
  #      docs/analysis/unsupported_spec.md §1).
  #   3. Aggregate structured Ambiguous entries (categories from
  #      docs/analysis/ambiguous_spec.md §2).
  #
  # Legacy API (`.unmapped`, `.warning`, `.buckets`, `.any_unsupported?`) is
  # kept for backward compatibility with existing rules classes.
  class Report
    # Structured Unsupported bucket — see unsupported_spec.md §3.
    class Unsupported
      CATEGORIES = %i[
        schemas statuses error_codes auth response_format
        endpoints webhook_signature fields content_type pagination
      ].freeze

      def initialize
        @entries = Hash.new { |h, k| h[k] = [] }
      end

      # @param category [Symbol]
      # @param element  [String]
      # @param reason   [String]
      # @param path     [String, nil]
      # @param hint     [String, nil]
      def add(category, element, reason, path: nil, hint: nil)
        raise ArgumentError, "unknown Unsupported category #{category}" unless CATEGORIES.include?(category)

        @entries[category] << { element: element, reason: reason, path: path, hint: hint }
      end

      def any?
        @entries.any? { |_, v| v.any? }
      end

      # @return [Hash{Symbol=>Array<Hash>}] in CATEGORIES order
      def to_h
        CATEGORIES.each_with_object({}) do |cat, acc|
          rows = @entries[cat]
          acc[cat] = rows unless rows.empty?
        end
      end
    end

    # Structured Ambiguous bucket — see ambiguous_spec.md §3.
    class Ambiguous
      CATEGORIES = %i[
        units
        signature_algo signature_encoding signature_body signature_format
        required_if
        credentials_access
        status_map_fallback error_map_fallback
      ].freeze

      def initialize
        @entries = Hash.new { |h, k| h[k] = [] }
      end

      # @param category      [Symbol]
      # @param subject       [String]
      # @param inferred      [Object]
      # @param source        [String]
      # @param override_yaml [String] ready-to-paste YAML snippet
      # @param spec_path     [String, nil]
      def add(category:, subject:, inferred:, source:, override_yaml:, spec_path: nil)
        raise ArgumentError, "unknown Ambiguous category #{category}" unless CATEGORIES.include?(category)

        @entries[category] << {
          subject:       subject,
          inferred:      inferred,
          source:        source,
          override_yaml: override_yaml,
          spec_path:     spec_path
        }
      end

      def any?
        @entries.any? { |_, v| v.any? }
      end

      def to_h
        CATEGORIES.each_with_object({}) do |cat, acc|
          rows = @entries[cat]
          acc[cat] = rows unless rows.empty?
        end
      end
    end

    attr_reader :buckets, :warnings, :unsupported, :ambiguous

    def initialize(out: $stdout)
      @out         = out
      @buckets     = Hash.new { |h, k| h[k] = [] }
      @warnings    = []
      @unsupported = Unsupported.new
      @ambiguous   = Ambiguous.new
    end

    def log(line = '')
      @out.puts(line)
    end

    # Aggregate report has content if either bucket is non-empty.
    def any?
      @unsupported.any? || @ambiguous.any?
    end

    # ---- Legacy API (kept for backward compat) ------------------------------

    def unmapped(kind, payload)
      @buckets[kind] << payload
    end

    def warning(kind, payload)
      @warnings << { kind: kind, payload: payload }
    end

    def any_unsupported?
      @buckets.any? { |_, list| list.any? } || @unsupported.any?
    end
  end
end
