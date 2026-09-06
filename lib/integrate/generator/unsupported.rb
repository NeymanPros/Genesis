# frozen_string_literal: true

require_relative 'base'

module Integrate
  module Generator
    # Renders `output/UNSUPPORTED.md` — a report of everything the generator
    # produced best-effort (Ambiguous) or could not handle (Unsupported).
    # File is only written when the report has content; otherwise the runner
    # skips the call entirely.
    #
    # See docs/analysis/unsupported_spec.md §2 and ambiguous_spec.md §5 for
    # the exact Markdown format.
    class Unsupported < Base
      def initialize(report, spec:, output_dir:)
        super()
        @report = report
        @spec = spec
        @output_dir = output_dir
      end

      # @return [String] rendered Markdown source
      def call
        render('UNSUPPORTED.md.erb', {
                 spec_title:   @spec.info.title,
                 spec_source:  spec_source_display,
                 unsupported:  @report.unsupported.to_h,
                 ambiguous:    @report.ambiguous.to_h,
                 has_any:      @report.any?
               })
      end

      private

      def spec_source_display
        raw = @spec.respond_to?(:raw_source) ? @spec.raw_source.to_s : ''
        cwd = Dir.pwd
        raw.start_with?(cwd) ? raw.delete_prefix(cwd + '/') : raw
      end
    end
  end
end
