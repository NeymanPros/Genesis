# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'fileutils'
require 'integrate/runner'

RSpec.describe 'PayCloud generation' do
  let(:tmpdir) { Dir.mktmpdir('paycloud') }
  after { FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir) }

  let(:paycloud_spec) { File.join(SpecPaths::ROOT, 'examples', 'paycloud_api.yaml') }

  it 'without overrides emits Ambiguous entries for signature body/format/encoding and credentials_access' do
    report = Integrate::Report.new(out: StringIO.new)
    Integrate::Runner.new(
      spec: paycloud_spec,
      provider: 'paycloud',
      lang: 'ruby',
      output: tmpdir,
      report: report
    ).call

    h = report.ambiguous.to_h
    expect(h).to have_key(:signature_body)
    expect(h).to have_key(:signature_format)
    expect(h).to have_key(:signature_encoding)
    expect(h).to have_key(:credentials_access)
    expect(File.exist?(File.join(tmpdir, 'UNSUPPORTED.md'))).to eq(true)
  end

  it 'generates a syntactically valid Ruby service file' do
    report = Integrate::Report.new(out: StringIO.new)
    Integrate::Runner.new(
      spec: paycloud_spec,
      provider: 'paycloud',
      lang: 'ruby',
      output: tmpdir,
      report: report
    ).call

    path = File.join(tmpdir, 'paycloud_service.rb')
    expect(File.exist?(path)).to eq(true)
    # ruby -c: syntax check
    stderr = `ruby -c #{path} 2>&1`
    expect(stderr).to include('Syntax OK')
  end
end
