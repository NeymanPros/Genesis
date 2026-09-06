# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'fileutils'
require 'tmpdir'
require 'integrate/runner'

RSpec.describe 'NovaPay with overrides' do
  let(:tmpdir) { Dir.mktmpdir('novapay-ov') }
  after { FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir) }

  it 'produces no Ambiguous entries when the full overrides file is supplied' do
    report = Integrate::Report.new(out: StringIO.new)
    Integrate::Runner.new(
      spec: SpecPaths::NOVAPAY,
      provider: 'novapay',
      lang: 'ruby',
      output: tmpdir,
      rules: File.join(SpecPaths::ROOT, 'examples', 'novapay_overrides.yaml'),
      report: report
    ).call

    expect(report.ambiguous.any?).to eq(false)
    expect(report.unsupported.any?).to eq(false)
    expect(File.exist?(File.join(tmpdir, 'UNSUPPORTED.md'))).to eq(false)
    expect(File.exist?(File.join(tmpdir, 'novapay_service.rb'))).to eq(true)
  end

  it 'produces Ambiguous entries when no overrides are supplied' do
    report = Integrate::Report.new(out: StringIO.new)
    Integrate::Runner.new(
      spec: SpecPaths::NOVAPAY,
      provider: 'novapay',
      lang: 'ruby',
      output: tmpdir,
      report: report
    ).call

    h = report.ambiguous.to_h
    expect(h).to have_key(:units)
    expect(h).to have_key(:signature_algo)
    expect(h).to have_key(:signature_encoding)
    expect(h).to have_key(:signature_body)
    expect(h).to have_key(:signature_format)
    expect(h).to have_key(:credentials_access)
    expect(File.exist?(File.join(tmpdir, 'UNSUPPORTED.md'))).to eq(true)
  end
end
