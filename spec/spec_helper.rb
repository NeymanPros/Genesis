# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'integrate'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'tmp/rspec.txt'
  config.disable_monkey_patching!
  config.warnings = false
  config.order = :random
  Kernel.srand(config.seed)
end

# Shared paths (used across specs).
module SpecPaths
  ROOT      = File.expand_path('..', __dir__)
  NOVAPAY   = File.join(ROOT, 'tasks', 'provider_api.yaml')
  CONFIG    = File.join(ROOT, 'config')
  FIXTURES  = File.join(ROOT, 'spec', 'fixtures')
  SUPPORT   = File.join(ROOT, 'spec', 'support')
end

# Lightweight fake HTTP client suitable for behaviour tests of the generated
# service — no WebMock/Faraday required. Records the last request and returns
# a canned response for the next call.
class FakeHttpClient
  Response = Struct.new(:status, :body, :headers) do
    def initialize(status:, body: {}, headers: {})
      super(status, body, headers)
    end
  end

  attr_reader :requests

  def initialize
    @requests = []
    @responses = { get: [], post: [] }
  end

  def stub(method, response)
    @responses[method] << response
    self
  end

  def get(url, **opts)
    perform(:get, url, opts)
  end

  def post(url, **opts)
    perform(:post, url, opts)
  end

  private

  def perform(method, url, opts)
    @requests << { method: method, url: url, **opts }
    (@responses[method].shift || Response.new(status: 200, body: {}))
  end
end

# Minimal operation double for behaviour tests.
class FakeOperation
  attr_accessor :id, :amount, :payout_requisite, :provider_operation_id, :idempotency_key

  def initialize(id: 'op_abc123', amount: 15_000, payout_requisite: nil, provider_operation_id: nil)
    @id = id
    @amount = amount
    @payout_requisite = payout_requisite || {
      'sbp' => { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Сбербанк' }
    }
    @provider_operation_id = provider_operation_id
  end
end
