# frozen_string_literal: true

require 'json'

module Integrate
  module Generator
    # Builds `output/fixtures.json`. Structure follows the 11 test cases from
    # docs/analysis/test_cases.md — see README section "fixtures.json" for
    # what each block represents.
    #
    # Data source order:
    #   1. `examples:` / `example:` blocks from the OpenAPI spec (real data).
    #   2. Synthesised placeholders when the spec has no example (marked with
    #      `_synthetic: true` so auditors can tell them apart).
    class Fixtures
      SYNTHETIC_ID = 'np_7f3a9b2c'

      def initialize(spec, report: nil)
        @spec = spec
        @report = report
      end

      # @return [String] JSON.pretty_generate
      def call
        data = {}
        data['_meta'] = meta
        data['create_request']  = create_block                if create_endpoint
        data['fetch_status']    = fetch_status_block          if status_endpoint
        data['cancel']          = cancel_block                if cancel_endpoint
        callbacks_block.each { |k, v| data[k] = v }
        JSON.pretty_generate(data)
      end

      private

      def meta
        {
          'provider'     => @spec.info.provider_slug,
          'generated_by' => 'integrate',
          'note'         => 'Data comes from OpenAPI examples where available; ' \
                            'synthetic blocks are marked with _synthetic: true.'
        }
      end

      # ---- create_request ----------------------------------------------------

      def create_block
        body_ex = examples_for(create_endpoint&.request_body).first&.value
        block = { 'request' => body_ex || synthetic_create_request }

        response_examples(create_endpoint).each do |code, example|
          block["response_#{code}"] = example
        end
        # Ensure we always have 4 canonical response cases even when the spec
        # omits examples for some (409 is missing in NovaPay).
        block['response_409'] ||= synthetic_response_409.merge('_synthetic' => true)
        block['_synthetic'] = true if body_ex.nil?
        block
      end

      def synthetic_create_request
        {
          'amount'      => 1_500_000,
          'currency'    => 'RUB',
          'external_id' => 'op_abc123',
          'recipient'   => { 'type' => 'sbp', 'phone' => '79001234567', 'bank_code' => '044525225' },
          '_synthetic'  => true
        }
      end

      def synthetic_response_409
        {
          'id'          => SYNTHETIC_ID,
          'external_id' => 'op_abc123',
          'status'      => 'processing',
          'amount'      => 1_500_000,
          'currency'    => 'RUB',
          'created_at'  => '2026-07-30T10:00:00Z'
        }
      end

      # ---- fetch_status ------------------------------------------------------

      def fetch_status_block
        block = { 'request' => { 'path' => status_endpoint_path } }
        examples = response_examples(status_endpoint)
        if examples['200']
          block['response_200'] = examples['200']
        else
          block['response_200'] = synthetic_fetch_status_200
        end
        block['response_404'] = examples['404'] || {
          'error' => { 'code' => 'not_found', 'message' => 'Payout not found' },
          '_synthetic' => true
        }
        block
      end

      def synthetic_fetch_status_200
        {
          'id'           => SYNTHETIC_ID,
          'external_id'  => 'op_abc123',
          'status'       => 'completed',
          'amount'       => 1_500_000,
          'currency'     => 'RUB',
          'completed_at' => '2026-07-30T10:05:00Z',
          '_synthetic'   => true
        }
      end

      def status_endpoint_path
        return "/payouts/#{SYNTHETIC_ID}" unless status_endpoint

        status_endpoint.path.gsub(/\{[^}]+\}/, SYNTHETIC_ID)
      end

      # ---- cancel ------------------------------------------------------------

      def cancel_block
        block = { 'request' => { 'path' => cancel_endpoint_path } }
        examples = response_examples(cancel_endpoint)
        block['response_200'] = examples['200'] || {
          'id' => SYNTHETIC_ID, 'status' => 'cancelled', '_synthetic' => true
        }
        block['response_409'] = examples['409'] || {
          'error' => { 'code' => 'invalid_status', 'message' => 'Cannot cancel payout in status completed' },
          '_synthetic' => true
        }
        block
      end

      def cancel_endpoint_path
        return "/payouts/#{SYNTHETIC_ID}/cancel" unless cancel_endpoint

        cancel_endpoint.path.gsub(/\{[^}]+\}/, SYNTHETIC_ID)
      end

      # ---- callbacks ---------------------------------------------------------

      def callbacks_block
        result = {}
        events = webhook_events
        by_event = callback_examples_by_event

        events.each do |event|
          key = "callback_#{event.split('.').last}"
          payload = by_event[event] || synthetic_callback_for(event)
          result[key] = {
            'payload' => payload,
            'expected_operation_status' => expected_status_for(event)
          }
          result[key]['_synthetic'] = true if by_event[event].nil?
        end
        result
      end

      def webhook_events
        webhook = @spec.webhooks.first
        events = webhook&.events || []
        return %w[payout.completed payout.failed payout.processing payout.cancelled] if events.empty?

        events.map(&:to_s)
      end

      def callback_examples_by_event
        endpoint = callback_endpoint
        return {} unless endpoint&.request_body

        examples_for(endpoint.request_body).each_with_object({}) do |ex, acc|
          value = ex.value
          next unless value.is_a?(Hash)

          event = value['event']
          acc[event.to_s] = value if event
        end
      end

      def synthetic_callback_for(event)
        base = { 'event' => event, 'payout_id' => SYNTHETIC_ID, 'external_id' => 'op_abc123' }
        case event
        when 'payout.completed'
          base.merge('status' => 'completed', 'completed_at' => '2026-07-30T10:05:00Z')
        when 'payout.failed'
          base.merge('status' => 'failed', 'error' => { 'code' => 'recipient_not_found', 'message' => 'Recipient account not found' })
        when 'payout.cancelled'
          base.merge('status' => 'cancelled')
        when 'payout.processing'
          base.merge('status' => 'processing')
        else
          base.merge('status' => 'unknown')
        end
      end

      def expected_status_for(event)
        case event
        when 'payout.completed'  then 'approved'
        when 'payout.failed', 'payout.cancelled' then 'rejected'
        when 'payout.processing' then 'in_progress'
        else 'in_progress'
        end
      end

      # ---- helpers -----------------------------------------------------------

      def response_examples(endpoint)
        return {} unless endpoint

        endpoint.responses.each_with_object({}) do |(code, response), acc|
          example = response.examples.first
          acc[code.to_s] = example.value if example
        end
      end

      def examples_for(request_body_or_response)
        return [] unless request_body_or_response.respond_to?(:examples)

        Array(request_body_or_response.examples)
      end

      def create_endpoint;   @spec.endpoints.find { |ep| ep.role == :create }; end
      def status_endpoint;   @spec.endpoints.find { |ep| ep.role == :status }; end
      def cancel_endpoint;   @spec.endpoints.find { |ep| ep.role == :cancel }; end
      def callback_endpoint; @spec.endpoints.find { |ep| ep.role == :callback }; end
    end
  end
end
