# frozen_string_literal: true

# Top-level namespace and entry point.
module Integrate
end

require_relative 'integrate/version'
require_relative 'integrate/errors'
require_relative 'integrate/ir'
require_relative 'integrate/parser/openapi'
require_relative 'integrate/rules/status_map'
require_relative 'integrate/rules/error_map'
require_relative 'integrate/rules/field_map'
require_relative 'integrate/rules/units_detection'
require_relative 'integrate/report'
require_relative 'integrate/generator/base'
require_relative 'integrate/generator/service'
require_relative 'integrate/generator/doc'
require_relative 'integrate/generator/fixtures'
require_relative 'integrate/runner'
require_relative 'integrate/cli'
