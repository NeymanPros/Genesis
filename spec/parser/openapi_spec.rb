# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Integrate::Parser::OpenApi do
  subject(:spec) { described_class.new(SpecPaths::NOVAPAY).parse }

  it 'extracts all 5 endpoints from NovaPay' do
    expect(spec.endpoints.size).to eq(5)
  end

  it 'classifies endpoint roles by heuristic' do
    roles = spec.endpoints.map(&:role)
    expect(roles).to contain_exactly(:create, :status, :cancel, :callback, :balance)
  end

  it 'detects the api_key auth scheme' do
    expect(spec.auth.type).to eq(:api_key)
    expect(spec.auth.header_or_param_name).to eq('X-API-Key')
    expect(spec.auth.scheme_name).to eq('ApiKeyAuth')
  end

  it 'detects the webhook and its HMAC-SHA256 signature' do
    expect(spec.webhooks.size).to eq(1)
    webhook = spec.webhooks.first
    expect(webhook.signature_header).to eq('X-NovaPay-Signature')
    expect(webhook.signature_algo).to eq(:hmac_sha256)
  end

  it 'resolves $ref inside request body schemas' do
    create_ep = spec.endpoints.find { |ep| ep.role == :create }
    props = create_ep.request_body.schema.properties
    expect(props.keys).to include('amount', 'currency', 'external_id', 'recipient')
    expect(props['amount'].minimum).to eq(100_000)
  end

  it 'raises Errno::ENOENT when the file is missing (CLI maps to exit 66)' do
    expect { described_class.new('/tmp/no_such_file.yaml') }
      .to raise_error(Errno::ENOENT, /Spec file not found/)
  end
end
