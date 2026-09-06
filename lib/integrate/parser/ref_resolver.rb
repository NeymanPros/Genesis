# frozen_string_literal: true

module Integrate
  module Parser
    # Walks a parsed OpenAPI YAML document and resolves `$ref` pointers of
    # the form `#/foo/bar/baz`. External refs (`file.yaml#/...` or URLs) are
    # not supported — they raise UnsupportedFeature.
    #
    # Behaviour:
    #   * `resolve(node)` returns the same node with `$ref` chains inlined.
    #   * Cycles are broken by caching in-progress refs; a repeated ref
    #     resolves to the shallow copy already produced.
    #   * Non-ref hashes/arrays are recursively resolved.
    class RefResolver
      def initialize(document)
        @document = document
        @cache = {}
      end

      def resolve(node)
        case node
        when Hash then resolve_hash(node)
        when Array then node.map { |el| resolve(el) }
        else node
        end
      end

      private

      def resolve_hash(hash)
        return resolve_ref(hash['$ref']) if hash.size == 1 && hash.key?('$ref')

        hash.each_with_object({}) do |(k, v), acc|
          acc[k] = v.is_a?(Hash) && v.key?('$ref') ? resolve_ref(v['$ref']) : resolve(v)
        end
      end

      def resolve_ref(ref)
        return @cache[ref] if @cache.key?(ref)

        raise Integrate::Errors::UnsupportedFeature, "External $ref not supported: #{ref}" unless ref.start_with?('#/')

        pointer = ref.delete_prefix('#/').split('/').map { |seg| unescape(seg) }
        target = pointer.reduce(@document) do |node, seg|
          raise Integrate::Errors::SpecInvalid, "Cannot resolve $ref #{ref}" unless node.is_a?(Hash) && node.key?(seg)

          node[seg]
        end

        # Cache the shallow container first to break cycles, then resolve deeply.
        @cache[ref] = target
        resolved = resolve(target)
        @cache[ref] = resolved
        resolved
      end

      def unescape(segment)
        segment.gsub('~1', '/').gsub('~0', '~')
      end
    end
  end
end
