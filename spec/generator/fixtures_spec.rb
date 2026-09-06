# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Integrate::Generator::Fixtures do
  subject(:raw) { described_class.new(spec).call }

  let(:spec) { Integrate::Parser::OpenApi.new(SpecPaths::NOVAPAY).parse }
  let(:parsed) { JSON.parse(raw) }

  it 'produces valid JSON' do
    expect { parsed }.not_to raise_error
  end

  it 'contains the 7 expected top-level fixture blocks plus _meta' do
    expect(parsed.keys).to include(
      '_meta',
      'create_request', 'fetch_status', 'cancel',
      'callback_completed', 'callback_failed',
      'callback_cancelled', 'callback_processing'
    )
  end

  it 'covers all 11+ scenarios' do
    scenarios = 0
    scenarios += parsed['create_request'].count { |k, _| k.start_with?('response_') || k == 'request' }
    scenarios += parsed['fetch_status'].count { |k, _| k.start_with?('response_') }
    scenarios += parsed['cancel'].count { |k, _| k.start_with?('response_') }
    scenarios += parsed.keys.count { |k| k.start_with?('callback_') }
    expect(scenarios).to be >= 11
  end

  it 'draws the create request body from the OpenAPI example' do
    req = parsed.dig('create_request', 'request')
    expect(req['amount']).to eq(1_500_000)
    expect(req['currency']).to eq('RUB')
    expect(req.dig('recipient', 'phone')).to eq('79001234567')
  end

  it 'includes response_201 with id + status' do
    expect(parsed.dig('create_request', 'response_201', 'id')).to eq('np_7f3a9b2c')
    expect(parsed.dig('create_request', 'response_201', 'status')).to eq('pending')
  end

  it 'includes response_422 with a validation error' do
    expect(parsed.dig('create_request', 'response_422', 'error', 'code')).to eq('validation_error')
  end

  it 'includes a synthetic response_409 for the idempotency duplicate case' do
    expect(parsed.dig('create_request', 'response_409')).to include('_synthetic' => true)
  end

  it 'marks synthetic fetch_status.response_200 while keeping the 404 example' do
    expect(parsed.dig('fetch_status', 'response_200')).to include('_synthetic' => true)
    expect(parsed.dig('fetch_status', 'response_404', 'error', 'code')).to eq('not_found')
  end

  it 'includes cancel response_409 with invalid_status' do
    expect(parsed.dig('cancel', 'response_409', 'error', 'code')).to eq('invalid_status')
  end

  it 'includes all 4 webhook callbacks with expected_operation_status' do
    %w[callback_completed callback_failed callback_cancelled callback_processing].each do |key|
      expect(parsed[key]).to include('payload', 'expected_operation_status')
    end
    expect(parsed.dig('callback_completed', 'expected_operation_status')).to eq('approved')
    expect(parsed.dig('callback_failed',    'expected_operation_status')).to eq('rejected')
    expect(parsed.dig('callback_processing','expected_operation_status')).to eq('in_progress')
  end
end
