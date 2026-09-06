# frozen_string_literal: true

module Integrate
  module Rules
    # Detects whether a numeric field carries minor units (копейки, cents) or
    # major units (rubles, dollars). Pure function — no YAML.
    module UnitsDetection
      MINOR_RE = /(коп(?:ей|ейк)|kopeck|minor[- ]?unit|smallest[- ]?unit|cent(?:avo)?s?|pence|paise)/i.freeze
      MAJOR_RE = /(рубл|доллар|евро|dollar|euro|major[- ]?unit)/i.freeze

      module_function

      # @param field [Integrate::Ir::Field]
      # @param report [Integrate::Report, nil]
      # @return [Symbol] :minor | :major | :unknown
      def detect(field, report: nil)
        type = field.type.to_s
        return :unknown unless %w[integer number].include?(type)

        desc = field.description.to_s
        return :minor if MINOR_RE.match?(desc)
        return :major if MAJOR_RE.match?(desc)

        if type == 'integer' && (field.minimum.to_i >= 100 || field.example.to_i >= 100)
          report&.warning(:units_guessed_minor, field)
          return :minor
        end

        report&.unmapped(:units, field)
        :unknown
      end
    end
  end
end
