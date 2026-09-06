# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Integrate::Generator::Doc do
  subject(:doc) { described_class.new(spec).call }

  let(:spec) { Integrate::Parser::OpenApi.new(SpecPaths::NOVAPAY).parse }

  it 'starts with the provider title as the H1 heading' do
    expect(doc).to match(/\A# NovaPay Payout API Integration Guide/)
  end

  it 'includes an Авторизация section with the API-Key details' do
    expect(doc).to include('## Авторизация')
    expect(doc).to include('X-API-Key')
    expect(doc).to include('credentials.api_key')
  end

  it 'lists all 5 endpoints in the Методы table' do
    expect(doc).to include('| create_request | POST /payouts')
    expect(doc).to include('| fetch_status | GET /payouts/{payout_id}')
    expect(doc).to include('| cancel_request | POST /payouts/{payout_id}/cancel')
    expect(doc).to include('| process_callback | POST /webhooks/payout')
    expect(doc).to include('| fetch_balance | GET /balance')
  end

  it 'renders the status mapping table with all 5 NovaPay values' do
    expect(doc).to include('## Маппинг статусов')
    %w[pending processing completed failed cancelled].each do |st|
      expect(doc).to include("| #{st} |")
    end
  end

  it 'renders two error tables — by HTTP status and by provider code' do
    expect(doc).to include('### По HTTP-статусу')
    expect(doc).to include('### По provider `error.code`')
    expect(doc).to include('| 400 | validation_error')
    expect(doc).to include('| rate_limit_exceeded | rate_limit |')
  end

  it 'includes a ProviderGateway config JSON snippet' do
    expect(doc).to include('## ProviderGateway config')
    expect(doc).to include('"gateway": "RUB_SBP_WITHDRAW"')
    expect(doc).to include('"external_method": "sbp_payout"')
  end

  it 'includes the Webhook signature section with all 4 events' do
    expect(doc).to include('## Webhook signature')
    expect(doc).to include('HMAC-SHA256')
    %w[payout.completed payout.failed payout.processing payout.cancelled].each do |ev|
      expect(doc).to include("`#{ev}`")
    end
  end

  it 'lists the required env variables' do
    expect(doc).to include('`NOVAPAY_BASE_URL`')
    expect(doc).to include('`NOVAPAY_API_KEY`')
    expect(doc).to include('`NOVAPAY_CALLBACK_SECRET`')
  end

  it 'includes a Как использовать section with a Ruby snippet' do
    expect(doc).to include('## Как использовать')
    expect(doc).to include('Provider::NovapayService.new')
    expect(doc).to include('service.check_conditions')
    expect(doc).to include('service.create_request')
  end
end
