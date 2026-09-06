# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Integrate::Rules::StatusMap do
  subject(:mapper) { described_class.new }

  it 'maps all 5 NovaPay statuses to the internal enum' do
    {
      'pending'    => 'in_progress',
      'processing' => 'in_progress',
      'completed'  => 'approved',
      'failed'     => 'rejected',
      'cancelled'  => 'rejected'
    }.each do |raw, internal|
      expect(mapper.apply(raw)).to eq(internal), "expected #{raw} -> #{internal}"
    end
  end

  it 'is case-insensitive' do
    expect(mapper.apply('COMPLETED')).to eq('approved')
  end

  it 'falls back to unknown and reports for unmapped values' do
    expect(mapper.apply('mystery_status')).to eq('unknown')
    expect(mapper.unmatched).to include('mystery_status')
  end

  it 'build_map excludes values that fall through to unknown' do
    result = mapper.build_map(%w[pending mystery_status completed])
    expect(result).to eq('pending' => 'in_progress', 'completed' => 'approved')
  end
end
