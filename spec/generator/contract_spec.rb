# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

# Contract-test: the generated <provider>_service.rb file must `require`
# cleanly against the reconstructed Provider::BaseService stub and expose
# the four contract methods. This is the key acceptance criterion for
# "generation of an integration service" from the task specification.
RSpec.describe 'Generated novapay_service.rb — contract' do
  GENERATED_DIR ||= File.join(Dir.mktmpdir, 'output')
  GENERATED_FILE ||= File.join(GENERATED_DIR, 'novapay_service.rb')

  before(:all) do
    FileUtils.mkdir_p(GENERATED_DIR)
    Integrate::Runner.new(
      spec: SpecPaths::NOVAPAY, provider: 'novapay', lang: 'ruby',
      output: GENERATED_DIR, report: Integrate::Report.new(out: StringIO.new)
    ).call
    unless defined?(Provider::NovapayService)
      load File.join(SpecPaths::SUPPORT, 'provider_base_stub.rb')
      load GENERATED_FILE
    end
  end

  it 'is syntactically valid Ruby' do
    expect(system('ruby', '-c', GENERATED_FILE, out: File::NULL, err: File::NULL)).to be(true)
  end

  it 'defines Provider::NovapayService inheriting from Provider::BaseService' do
    expect(Provider::NovapayService.ancestors).to include(Provider::BaseService)
  end

  it 'exposes the four contract methods' do
    instance = Provider::NovapayService.new
    %i[create_request fetch_status process_callback check_conditions].each do |m|
      expect(instance).to respond_to(m)
    end
  end

  it 'freezes STATUS_MAP with every NovaPay status' do
    expect(Provider::NovapayService::STATUS_MAP).to be_frozen
    expect(Provider::NovapayService::STATUS_MAP.keys)
      .to include('pending', 'processing', 'completed', 'failed', 'cancelled')
  end

  it 'freezes ERROR_MAP with the HTTP codes seen in the spec' do
    map = Provider::NovapayService::ERROR_MAP
    expect(map).to be_frozen
    [400, 401, 402, 422, 429, 500].each { |c| expect(map).to have_key(c) }
  end

  it 'defines the PROVIDER_ERROR_MAP extension' do
    expect(Provider::NovapayService::PROVIDER_ERROR_MAP)
      .to include('validation_error', 'insufficient_balance', 'rate_limit_exceeded')
  end
end
