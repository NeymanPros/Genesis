# frozen_string_literal: true

require 'yaml'

module Integrate
  module Rules
    # Assigns a semantic role (:amount, :currency, :external_id, ...) to each
    # OpenAPI field by matching name / type / description / enum against rules
    # from config/field_rules.yaml.
    #
    # Match priority per rule (all must hold):
    #   * `name_aliases` — at least one regex matches the field name.
    #   * `types`        — field type is in the whitelist (or rule omits it).
    #   * `desc_match` / `enum_match` — if either is set, at least one must
    #     match. If both are absent, name+type is enough.
    class FieldMap
      def initialize(rules_path = nil, report: nil)
        @rules_path = rules_path || default_path
        @report     = report
        load_rules
      end

      # @param field [Integrate::Ir::Field]
      # @return [Symbol]
      def classify(field)
        name_lc = field.name.to_s.downcase
        desc    = field.description.to_s
        type    = field.type.to_s
        enum    = Array(field.enum).map(&:to_s).join(' ')

        rule = @rules.find { |r| rule_matches?(r, name_lc: name_lc, type: type, desc: desc, enum: enum) }
        return rule[:role] if rule

        # Only body-level fields are reported as unmapped. Object containers
        # (like `recipient`) are skipped because the generator recurses into
        # their properties and maps them individually.
        return @fallback if field.type.to_s == 'object'

        @report&.unmapped(:field, field) if field.location == :body
        @fallback
      end

      private

      def default_path
        File.expand_path('../../../config/field_rules.yaml', __dir__)
      end

      def load_rules
        data = YAML.safe_load(File.read(@rules_path))
        @rules = Array(data['rules']).map do |r|
          {
            role: r.fetch('role').to_sym,
            name_aliases: Array(r['name_aliases']).map { |p| Regexp.new(p, Regexp::IGNORECASE) },
            types: r['types'],
            desc_regex: r['desc_match'] ? Regexp.new(r['desc_match'], Regexp::IGNORECASE) : nil,
            enum_regex: r['enum_match'] ? Regexp.new(r['enum_match'], Regexp::IGNORECASE) : nil
          }
        end
        @fallback = (data['fallback'] || 'unknown').to_sym
      end

      def rule_matches?(rule, name_lc:, type:, desc:, enum:)
        return false unless rule[:name_aliases].any? { |re| re.match?(name_lc) }
        return false if rule[:types] && !rule[:types].include?(type)
        return true unless rule[:desc_regex] || rule[:enum_regex]

        (rule[:desc_regex] && rule[:desc_regex].match?(desc)) ||
          (rule[:enum_regex] && rule[:enum_regex].match?(enum))
      end
    end
  end
end
