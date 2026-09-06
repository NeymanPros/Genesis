# frozen_string_literal: true

module Integrate
  module Parser
    # Deterministic classifier for endpoint roles (:create/:status/:cancel/
    # :balance/:callback/:unknown). Rules are taken verbatim from
    # docs/analysis/ir_schema.md §4.
    module RoleClassifier
      module_function

      # Sub-path patterns that map to the :cancel role. `/void` and `/refund`
      # are semantically equivalent to `/cancel` for the purposes of the
      # generator (PayCloud uses /void, some providers use /refund).
      CANCEL_PATTERNS = %r{/(cancel|void|refund)(/|\z)}.freeze

      # @param method  [Symbol] :get, :post, ...
      # @param path    [String] e.g. `/payouts/{payout_id}/cancel`
      # @param tags    [Array<String>]
      # @param request_body [Hash, nil]
      # @return [Symbol]
      def classify(method:, path:, tags:, request_body:)
        return :callback if webhook?(path: path, tags: tags)
        return :cancel   if method == :post && path.match?(CANCEL_PATTERNS)
        return :create   if method == :post && request_body && path !~ %r{/(cancel|void|refund|status)(/|\z)}
        return :status   if method == :get  && path.match?(/\{[^}]+\}\z/)
        return :balance  if method == :get  && path.match?(/balance|account/i)

        :unknown
      end

      def webhook?(path:, tags:)
        # Recognise standard webhook path prefixes: /webhook, /webhooks/*,
        # and PayCloud-style /callbacks (top-level, without trailing slash).
        return true if path.match?(%r{/webhooks?(/|\z)}i)
        return true if path.match?(%r{/callbacks?(/|\z)}i)
        return true if tags.any? { |t| t.to_s.match?(/webhook|callback/i) }

        false
      end
    end
  end
end
