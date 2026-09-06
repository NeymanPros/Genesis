# frozen_string_literal: true

require 'spec_helper'
require 'integrate/rules/overrides'
require 'integrate/errors'
require 'tempfile'

RSpec.describe Integrate::Rules::Overrides do
  describe '.empty' do
    it 'returns an Overrides with all defaults nil / empty' do
      ov = described_class.empty
      expect(ov.amount_unit).to be_nil
      expect(ov.required_if).to eq([])
      expect(ov.signature_algo).to be_nil
      expect(ov.signature_encoding).to be_nil
      expect(ov.signature_body).to be_nil
      expect(ov.signature_format).to be_nil
      expect(ov.credentials_access).to be_nil
      expect(ov.status_map).to eq({})
      expect(ov.error_map).to eq({})
    end
  end

  describe '.from_rules_file' do
    it 'returns .empty for nil path' do
      expect(described_class.from_rules_file(nil).amount_unit).to be_nil
    end

    it 'returns .empty when file has no overrides key' do
      Tempfile.create(['rules', '.yaml']) do |f|
        f.write("status_rules: {}\n")
        f.flush
        expect(described_class.from_rules_file(f.path).amount_unit).to be_nil
      end
    end

    it 'loads and symbolizes enum values' do
      Tempfile.create(['rules', '.yaml']) do |f|
        f.write(<<~YAML)
          overrides:
            amount_unit: minor
            signature:
              algo: hmac_sha512
              encoding: base64
              body: json
              format: stripe
            credentials_access: method
            status_map:
              queued: in_progress
            error_map:
              kyc_required: invalid_credentials
            required_if:
              - { field: bank_code, when: { type: sbp } }
        YAML
        f.flush
        ov = described_class.from_rules_file(f.path)
        expect(ov.amount_unit).to eq(:minor)
        expect(ov.signature_algo).to eq(:hmac_sha512)
        expect(ov.signature_encoding).to eq(:base64)
        expect(ov.signature_body).to eq(:json)
        expect(ov.signature_format).to eq(:stripe)
        expect(ov.credentials_access).to eq(:method)
        expect(ov.status_map).to eq('queued' => 'in_progress')
        expect(ov.error_map).to eq('kyc_required' => 'invalid_credentials')
        expect(ov.required_if.first[:field]).to eq('bank_code')
      end
    end

    it 'loads examples/novapay_overrides.yaml without error' do
      path = File.expand_path('../../examples/novapay_overrides.yaml', __dir__)
      ov = described_class.from_rules_file(path)
      expect(ov.amount_unit).to eq(:minor)
      expect(ov.signature_algo).to eq(:hmac_sha256)
      expect(ov.credentials_access).to eq(:hash)
    end

    it 'loads examples/paycloud_overrides.yaml without error' do
      path = File.expand_path('../../examples/paycloud_overrides.yaml', __dir__)
      ov = described_class.from_rules_file(path)
      expect(ov.amount_unit).to eq(:major)
      expect(ov.signature_algo).to eq(:hmac_sha512)
      expect(ov.signature_format).to eq(:stripe)
    end
  end

  describe 'validation' do
    it 'raises InvalidOverride for bad amount_unit' do
      expect { described_class.new('amount_unit' => 'micro') }
        .to raise_error(Integrate::Errors::InvalidOverride, /amount_unit/)
    end

    it 'raises InvalidOverride for bad signature.algo' do
      expect { described_class.new('signature' => { 'algo' => 'md5' }) }
        .to raise_error(Integrate::Errors::InvalidOverride, /signature\.algo/)
    end

    it 'raises InvalidOverride for bad credentials_access' do
      expect { described_class.new('credentials_access' => 'env') }
        .to raise_error(Integrate::Errors::InvalidOverride, /credentials_access/)
    end

    it 'raises InvalidOverride for bad status_map value' do
      expect { described_class.new('status_map' => { 'queued' => 'partially_okay' }) }
        .to raise_error(Integrate::Errors::InvalidOverride, /status_map/)
    end

    it 'raises InvalidOverride when required_if entry is malformed' do
      expect { described_class.new('required_if' => [{ 'field' => 'x' }]) }
        .to raise_error(Integrate::Errors::InvalidOverride, /required_if/)
    end

    it 'accepts empty overrides section' do
      expect { described_class.new({}) }.not_to raise_error
    end
  end
end
