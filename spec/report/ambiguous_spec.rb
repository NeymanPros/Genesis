# frozen_string_literal: true

require 'spec_helper'
require 'integrate/report'

RSpec.describe Integrate::Report::Ambiguous do
  subject(:amb) { described_class.new }

  describe '#any?' do
    it 'is false on fresh instance' do
      expect(amb.any?).to eq(false)
    end

    it 'is true after add' do
      amb.add(category: :units, subject: 'amount', inferred: :minor,
              source: 'desc', override_yaml: "overrides:\n")
      expect(amb.any?).to eq(true)
    end
  end

  describe '#add' do
    it 'raises for unknown category' do
      expect do
        amb.add(category: :bogus, subject: 'x', inferred: :y,
                source: 's', override_yaml: 'yaml')
      end.to raise_error(ArgumentError, /unknown Ambiguous category/)
    end

    it 'accepts known categories and stores metadata' do
      amb.add(category: :signature_algo, subject: 'X-Sig',
              inferred: :hmac_sha256, source: 'x',
              override_yaml: 'y', spec_path: 'p')
      expect(amb.to_h[:signature_algo].first[:spec_path]).to eq('p')
    end
  end

  describe '#to_h' do
    it 'returns categories in canonical order' do
      amb.add(category: :credentials_access, subject: 'c', inferred: :hash,
              source: 's', override_yaml: 'y')
      amb.add(category: :units, subject: 'amount', inferred: :minor,
              source: 's', override_yaml: 'y')
      expect(amb.to_h.keys).to eq(%i[units credentials_access])
    end

    it 'omits empty categories' do
      amb.add(category: :units, subject: 'amount', inferred: :minor,
              source: 's', override_yaml: 'y')
      expect(amb.to_h.keys).to eq(%i[units])
    end
  end
end

RSpec.describe Integrate::Report do
  it 'exposes .unsupported and .ambiguous' do
    r = described_class.new
    expect(r.unsupported).to be_a(Integrate::Report::Unsupported)
    expect(r.ambiguous).to be_a(Integrate::Report::Ambiguous)
  end

  it 'aggregates .any? across both buckets' do
    r = described_class.new
    expect(r.any?).to eq(false)
    r.ambiguous.add(category: :units, subject: 'amount', inferred: :minor,
                    source: 's', override_yaml: 'y')
    expect(r.any?).to eq(true)
  end
end
