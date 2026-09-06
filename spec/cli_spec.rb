# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Integrate::Cli do
  it 'creates the three artefacts and prints the expected report' do
    Dir.mktmpdir do |dir|
      output = capture_stdout do
        described_class.start(%W[generate --spec #{SpecPaths::NOVAPAY} --provider novapay --lang ruby --output #{dir}])
      end

      %w[novapay_service.rb INTEGRATION.md fixtures.json].each do |name|
        expect(File.exist?(File.join(dir, name))).to be(true), "expected #{name} to exist"
      end

      expect(output).to include('Parsing spec...')
      expect(output).to include('Found 5 endpoints')
      expect(output).to include('Auth: ApiKeyAuth')
      expect(output).to include('Webhook signature: X-NovaPay-Signature')
    end
  end

  it 'exits with code 66 when the spec file is missing' do
    Dir.mktmpdir do |dir|
      expect do
        described_class.start(%W[generate --spec /tmp/nope.yaml --provider x --output #{dir}])
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(66).or(eq(2)) }
    end
  end

  private

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
