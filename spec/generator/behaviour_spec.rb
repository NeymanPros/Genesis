# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'openssl'
require 'json'

# Behaviour-tests for the generated service. We generate the file, load it
# against the Provider::BaseService stub, wire a FakeHttpClient into the
# instance, and drive the service through create_request / fetch_status /
# process_callback / cancel_request paths — asserting on the HTTP calls
# emitted and on the Result returned.
RSpec.describe 'Generated novapay_service.rb — behaviour' do
  BEHAVIOUR_DIR ||= File.join(Dir.mktmpdir, 'output')
  BEHAVIOUR_FILE ||= File.join(BEHAVIOUR_DIR, 'novapay_service.rb')

  let(:client) { FakeHttpClient.new }
  let(:secret) { 'test-callback-secret' }
  let(:service) do
    Provider::NovapayService.new(client: client, credentials: { 'api_key' => 'test-key', 'callback_secret' => secret })
  end

  before(:all) do
    FileUtils.mkdir_p(BEHAVIOUR_DIR)
    Integrate::Runner.new(
      spec: SpecPaths::NOVAPAY, provider: 'novapay', lang: 'ruby',
      output: BEHAVIOUR_DIR, report: Integrate::Report.new(out: StringIO.new)
    ).call
    # If the contract-test suite already loaded the class, re-loading here
    # would emit "already initialized constant" warnings; skip.
    unless defined?(Provider::NovapayService)
      load File.join(SpecPaths::SUPPORT, 'provider_base_stub.rb')
      load BEHAVIOUR_FILE
    end
  end

  describe '#create_request' do
    let(:operation) { FakeOperation.new(id: 'op_abc123', amount: 15_000) }

    it 'POSTs to /payouts with the correct payload and headers' do
      client.stub(:post, FakeHttpClient::Response.new(status: 201, body: { 'id' => 'np_777', 'status' => 'pending' }))

      result = service.create_request(operation)

      req = client.requests.last
      expect(req[:method]).to eq(:post)
      expect(req[:url]).to end_with('/payouts')
      expect(req[:json]).to include(
        amount: 1_500_000,
        currency: 'RUB',
        external_id: 'op_abc123'
      )
      expect(req[:json][:recipient]).to include(type: 'sbp', phone: '79001234567')
      expect(req[:headers]).to include('X-API-Key' => 'test-key')
      expect(req[:headers]).to have_key('Idempotency-Key')
      expect(result).to be_success
      # The service does NOT mutate `operation`; provider id is returned inside
      # `result.payload` and the platform persists it separately.
      expect(result.payload['id']).to eq('np_777')
      expect(operation.provider_operation_id).to be_nil
    end

    it 'returns failure(:unprocessable_entity) on a 422 validation error' do
      client.stub(:post, FakeHttpClient::Response.new(
        status: 422,
        body: { 'error' => { 'code' => 'validation_error', 'message' => 'Amount must be at least 100000 kopecks' } }
      ))

      result = service.create_request(operation)

      expect(result).to be_failed
      expect(result.status_sym).to eq(:unprocessable_entity)
      expect(result.message_key).to eq('provider.validation_error')
    end

    it 'treats a 409 duplicate as success' do
      client.stub(:post, FakeHttpClient::Response.new(status: 409, body: { 'id' => 'np_dup' }))

      result = service.create_request(operation)

      expect(result).to be_success
      # Same rule as 201: no mutation of `operation`, id lives in result.payload.
      expect(result.payload['id']).to eq('np_dup')
      expect(operation.provider_operation_id).to be_nil
    end

    it 'converts Provider::RateLimitError into :too_many_requests failure' do
      # Force the raise from within the client — same shape BaseService uses on 429.
      client.define_singleton_method(:post) { |*_a, **_k| raise Provider::RateLimitError }

      result = service.create_request(operation)

      expect(result).to be_failed
      expect(result.status_sym).to eq(:too_many_requests)
      expect(result.message_key).to eq('provider.rate_limit')
    end
  end

  describe '#fetch_status' do
    let(:operation) { FakeOperation.new(provider_operation_id: 'np_7f3a9b2c') }

    it 'GETs the payout by id and maps the returned status' do
      client.stub(:get, FakeHttpClient::Response.new(status: 200, body: { 'status' => 'completed' }))

      status = service.fetch_status(operation)

      expect(client.requests.last[:url]).to end_with('/payouts/np_7f3a9b2c')
      expect(status).to eq('approved')
    end

    it 'returns in_progress for a 404 (safe default)' do
      client.stub(:get, FakeHttpClient::Response.new(status: 404, body: { 'error' => { 'code' => 'not_found' } }))

      expect(service.fetch_status(operation)).to eq('in_progress')
    end
  end

  describe '#check_conditions' do
    it 'rejects amounts below the provider minimum' do
      operation = FakeOperation.new(amount: 500)
      result = service.check_conditions(operation, 'create')

      expect(result).to be_failed
      expect(result.message_key).to eq('amount_too_low')
    end

    it 'passes when the amount clears the minimum' do
      operation = FakeOperation.new(amount: 5_000)
      expect(service.check_conditions(operation, 'create')).to be_success
    end
  end

  describe '#process_callback' do
    def signed(payload)
      raw = JSON.dump(payload)
      payload.merge(
        '_raw_body'  => raw,
        '_signature' => OpenSSL::HMAC.hexdigest('SHA256', secret, raw)
      )
    end

    it 'approves the operation on payout.completed with a valid signature' do
      payload = signed('event' => 'payout.completed', 'payout_id' => 'np_1')

      service.process_callback(payload)

      expect(service.approved).to include('np_1')
    end

    it 'rejects the operation on payout.failed with error code' do
      payload = signed(
        'event' => 'payout.failed',
        'payout_id' => 'np_2',
        'error' => { 'code' => 'recipient_not_found' }
      )

      service.process_callback(payload)

      expect(service.rejected).to include(['np_2', 'recipient_not_found'])
    end

    it 'raises UnauthorizedError on an invalid signature' do
      payload = { 'event' => 'payout.completed', 'payout_id' => 'np_3', '_signature' => 'bad' }

      expect { service.process_callback(payload) }.to raise_error(Provider::UnauthorizedError)
    end
  end

  describe '#cancel_request' do
    let(:operation) { FakeOperation.new(provider_operation_id: 'np_9') }

    it 'POSTs to /payouts/{id}/cancel' do
      client.stub(:post, FakeHttpClient::Response.new(status: 200, body: { 'status' => 'cancelled' }))

      service.cancel_request(operation)

      expect(client.requests.last[:url]).to end_with('/payouts/np_9/cancel')
    end

    it 'returns failure(:conflict) on 409 invalid_status' do
      client.stub(:post, FakeHttpClient::Response.new(
        status: 409, body: { 'error' => { 'code' => 'invalid_status' } }
      ))

      result = service.cancel_request(operation)

      expect(result).to be_failed
      expect(result.status_sym).to eq(:conflict)
      expect(result.message_key).to eq('provider.invalid_status')
    end
  end
end
