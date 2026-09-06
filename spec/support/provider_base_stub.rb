# frozen_string_literal: true

# Minimal in-memory reproduction of Space Payments' Provider::BaseService,
# enough to `require` and instantiate the generated <provider>_service.rb
# outside of a Rails app.
#
# Contract source: docs/research/base_service_contract.md §3.
#
# NOTE: The task specification (see /tmp/docx_extract/text.txt line 23) opens
# `class Provider` — a class, not a module. To keep the generated file
# byte-compatible with the reference, this stub defines Provider as a class
# as well, then re-opens it with the same shape from the generator side.
class Provider
  class RateLimitError    < StandardError; end
  class UnauthorizedError < StandardError; end
  class ValidationError   < StandardError; end

  class BaseService
    Result = Struct.new(:success, :status_sym, :message_key, :payload) do
      def failed?  = !success
      def success? = success
    end

    def initialize(client: nil, credentials: {})
      @client = client
      @credentials = credentials
      @approved = []
      @rejected = []
    end

    attr_reader :credentials, :approved, :rejected

    def client = @client

    def success(payload = nil) = Result.new(true, :ok, nil, payload)
    def failure(sym, key)      = Result.new(false, sym, key, nil)

    def check_conditions(_operation, _request_method) = success

    def approve_operation(id)
      @approved << id
      success
    end

    def reject_operation(id, code)
      @rejected << [id, code]
      success
    end

    def map_status(provider_status)
      self.class.const_get(:STATUS_MAP).fetch(provider_status.to_s, 'in_progress')
    end
  end
end
