# frozen_string_literal: true

module Integrate
  # All errors raised by the generator inherit from Integrate::Error so callers
  # can rescue a single hierarchy. Each subclass maps to a distinct exit code
  # in Integrate::Cli.
  module Errors
    class Error < StandardError; end

    # Raised when the input OpenAPI document is malformed or violates the
    # invariants required for meaningful generation (missing paths, etc.).
    class SpecInvalid < Error; end

    # Raised by parsers/generators when an OpenAPI feature is theoretically
    # valid but not yet handled by this tool (e.g. oauth2 authorization_code).
    class UnsupportedFeature < Error; end

    # Raised by generators when an ERB template fails to render.
    class TemplateError < Error; end

    # Raised by IR constructors when invariants are violated.
    class IrInvalid < Error; end

    # Raised by Rules::Overrides when the user-provided YAML contains an
    # unsupported value (bad enum, wrong shape, etc). Mapped to CLI exit
    # code 65 (EX_DATAERR).
    class InvalidOverride < Error; end
  end
end
