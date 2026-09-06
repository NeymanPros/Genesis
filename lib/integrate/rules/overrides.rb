# frozen_string_literal: true

require 'yaml'
require_relative '../errors'

module Integrate
  module Rules
    # Loads and validates the `overrides:` section of a user-rules YAML file.
    # Provides an immutable set of accessors used by the generator to bypass
    # heuristics (see docs/analysis/overrides_spec.md).
    #
    # All primitive knobs default to nil / [] / {} — absence of an override
    # simply means the generator falls back to its heuristic + Ambiguous
    # report entry.
    class Overrides
      AMOUNT_UNIT_VALUES        = %i[minor major].freeze
      SIGNATURE_ALGO_VALUES     = %i[hmac_sha256 hmac_sha512 hmac_sha1].freeze
      SIGNATURE_ENCODING_VALUES = %i[hex base64].freeze
      SIGNATURE_BODY_VALUES     = %i[raw json].freeze
      SIGNATURE_FORMAT_VALUES   = %i[plain stripe].freeze
      CREDENTIALS_ACCESS_VALUES = %i[hash method].freeze
      STATUS_MAP_VALUES         = %w[in_progress approved rejected unknown].freeze

      # Build an Overrides directly from a Hash (already parsed from YAML).
      #
      # @param section [Hash, nil] the value of the `overrides:` key.
      def initialize(section = nil)
        @data = merge_defaults(deep_symbolize(section || {}))
        validate!
      end

      # Load overrides from a user-rules YAML file. Returns Overrides.empty
      # if `path` is nil or the file does not contain an `overrides:` key.
      #
      # @param path [String, nil]
      # @return [Overrides]
      def self.from_rules_file(path)
        return empty if path.nil? || path.to_s.empty?

        raw = YAML.safe_load(File.read(path), aliases: false, permitted_classes: [])
        section = raw.is_a?(Hash) ? raw['overrides'] : nil
        new(section)
      end

      # An Overrides object with all defaults (nothing overridden).
      # @return [Overrides]
      def self.empty
        new({})
      end

      def amount_unit;        @data[:amount_unit]; end
      def required_if;        @data[:required_if]; end
      def signature_algo;     @data[:signature][:algo]; end
      def signature_encoding; @data[:signature][:encoding]; end
      def signature_body;     @data[:signature][:body]; end
      def signature_format;   @data[:signature][:format]; end
      def credentials_access; @data[:credentials_access]; end
      def status_map;         @data[:status_map]; end
      def error_map;          @data[:error_map]; end

      private

      def merge_defaults(section)
        sig = section[:signature].is_a?(Hash) ? section[:signature] : {}
        {
          amount_unit:        section[:amount_unit],
          required_if:        Array(section[:required_if]),
          signature: {
            algo:     section.dig(:signature, :algo) || sig[:algo],
            encoding: section.dig(:signature, :encoding) || sig[:encoding],
            body:     section.dig(:signature, :body) || sig[:body],
            format:   section.dig(:signature, :format) || sig[:format]
          },
          credentials_access: section[:credentials_access],
          status_map:         (section[:status_map] || {}),
          error_map:          (section[:error_map] || {})
        }.tap do |d|
          # Symbolize enum-style scalars for consistent comparison downstream.
          d[:amount_unit]        = d[:amount_unit]&.to_sym
          d[:signature][:algo]     = d[:signature][:algo]&.to_sym
          d[:signature][:encoding] = d[:signature][:encoding]&.to_sym
          d[:signature][:body]     = d[:signature][:body]&.to_sym
          d[:signature][:format]   = d[:signature][:format]&.to_sym
          d[:credentials_access]   = d[:credentials_access]&.to_sym
          # status_map / error_map values stay as strings (embedded verbatim
          # into generated code as literals).
          d[:status_map] = stringify_hash(d[:status_map])
          d[:error_map]  = stringify_hash(d[:error_map])
        end
      end

      def stringify_hash(h)
        (h || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end

      def deep_symbolize(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = deep_symbolize(v) }
        when Array then obj.map { |x| deep_symbolize(x) }
        else obj
        end
      end

      def validate!
        validate_enum!(:amount_unit, @data[:amount_unit], AMOUNT_UNIT_VALUES)
        validate_enum!('signature.algo',     @data[:signature][:algo],     SIGNATURE_ALGO_VALUES)
        validate_enum!('signature.encoding', @data[:signature][:encoding], SIGNATURE_ENCODING_VALUES)
        validate_enum!('signature.body',     @data[:signature][:body],     SIGNATURE_BODY_VALUES)
        validate_enum!('signature.format',   @data[:signature][:format],   SIGNATURE_FORMAT_VALUES)
        validate_enum!(:credentials_access, @data[:credentials_access], CREDENTIALS_ACCESS_VALUES)
        validate_required_if!
        validate_status_map!
        validate_error_map!
      end

      def validate_enum!(key, value, allowed)
        return if value.nil?
        return if allowed.include?(value)

        raise Integrate::Errors::InvalidOverride,
              "overrides.#{key}: invalid value #{value.inspect}, expected one of " \
              "#{allowed.map(&:to_s).join(', ')}"
      end

      def validate_required_if!
        list = @data[:required_if]
        raise Integrate::Errors::InvalidOverride, 'overrides.required_if: must be an array' unless list.is_a?(Array)

        list.each_with_index do |entry, i|
          unless entry.is_a?(Hash) && entry[:field] && entry[:when].is_a?(Hash)
            raise Integrate::Errors::InvalidOverride,
                  "overrides.required_if[#{i}]: expected { field: <name>, when: { k: v, ... } }, got #{entry.inspect}"
          end
        end
      end

      def validate_status_map!
        @data[:status_map].each do |k, v|
          unless STATUS_MAP_VALUES.include?(v)
            raise Integrate::Errors::InvalidOverride,
                  "overrides.status_map[#{k.inspect}]: invalid value #{v.inspect}, expected one of " \
                  "#{STATUS_MAP_VALUES.join(', ')}"
          end
        end
      end

      def validate_error_map!
        @data[:error_map].each do |k, v|
          if v.to_s.empty?
            raise Integrate::Errors::InvalidOverride,
                  "overrides.error_map[#{k.inspect}]: value must be a non-empty string"
          end
        end
      end
    end
  end
end
