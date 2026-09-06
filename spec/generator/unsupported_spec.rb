# frozen_string_literal: true

require 'spec_helper'
require 'integrate/report'
require 'integrate/generator/unsupported'

RSpec.describe Integrate::Generator::Unsupported do
  let(:info) { double('Info', title: 'Some Provider') }
  let(:spec) { double('Spec', info: info, raw_source: '/tmp/spec.yaml') }
  let(:report) { Integrate::Report.new }
  let(:generator) { described_class.new(report, spec: spec, output_dir: '/tmp/out') }

  context 'with only unsupported entries' do
    before do
      report.unsupported.add(:endpoints, 'POST /v2/void',
                             'role classifier returned :unknown',
                             path: 'paths./v2/void.post',
                             hint: 'add rule')
    end

    it 'renders the Unsupported section' do
      md = generator.call
      expect(md).to include('## Endpoints')
      expect(md).to include('POST /v2/void')
      expect(md).not_to include('## Ambiguous')
    end
  end

  context 'with only ambiguous entries' do
    before do
      report.ambiguous.add(category: :units, subject: 'amount',
                           inferred: :minor, source: 'desc',
                           override_yaml: "overrides:\n  amount_unit: minor\n",
                           spec_path: 'properties.amount.description')
    end

    it 'renders the Ambiguous section with the YAML fragment' do
      md = generator.call
      expect(md).to include('## Ambiguous')
      expect(md).to include('amount → minor (units)')
      expect(md).to include('```yaml')
      expect(md).to include('overrides:')
      expect(md).to include('amount_unit: minor')
    end
  end

  context 'with both sections' do
    before do
      report.unsupported.add(:webhook_signature, 'X-Sig',
                             'Stripe-style HMAC', path: 'p', hint: 'confirm')
      report.ambiguous.add(category: :credentials_access, subject: 'credentials',
                           inferred: :hash, source: 'host-side',
                           override_yaml: "overrides:\n  credentials_access: hash\n")
    end

    it 'renders both sections' do
      md = generator.call
      expect(md).to match(/## Webhook Signature.*## Ambiguous/m)
    end
  end

  context 'with empty report' do
    it 'renders the "all supported" placeholder' do
      md = generator.call
      expect(md).to include('_Всё поддержано и однозначно._')
    end
  end
end
