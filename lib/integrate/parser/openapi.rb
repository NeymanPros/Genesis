# frozen_string_literal: true

require 'date'
require 'yaml'
require 'set'

require_relative 'ref_resolver'
require_relative 'role_classifier'

module Integrate
  module Parser
    # Turns an OpenAPI 3.0.x YAML file into an Integrate::Ir::Spec.
    #
    # Uses `YAML.safe_load` + a hand-rolled `RefResolver` rather than the
    # `openapi3_parser` gem — fully deterministic, no gem-side quirks, and
    # every access is a hash lookup by a well-known key.
    class OpenApi
      HTTP_METHODS = %w[get post put patch delete head options trace].freeze

      def initialize(path)
        @path = File.expand_path(path)
        # Use Errno::ENOENT (UNIX EX_NOINPUT=66) for missing file, keep SpecInvalid
        # for malformed/unparseable YAML. CLI translates each into its own exit code.
        raise Errno::ENOENT, "Spec file not found: #{path}" unless File.file?(@path)
      end

      # @return [Integrate::Ir::Spec]
      def parse
        doc = load_document
        @resolver = RefResolver.new(doc)

        Integrate::Ir::Spec.new(
          info: build_info(doc.fetch('info', {})),
          servers: build_servers(doc.fetch('servers', [])),
          endpoints: build_endpoints(doc),
          auth: build_auth(doc),
          webhooks: build_webhooks(doc),
          schemas: build_schemas(doc),
          raw_source: @path,
          openapi_version: doc.fetch('openapi', '3.0.0')
        )
      end

      # ---- Document loading ---------------------------------------------------

      def load_document
        raw = File.read(@path)
        doc = YAML.safe_load(raw, aliases: true, permitted_classes: [Date, Time])
        raise Integrate::Errors::SpecInvalid, "Spec root must be a mapping: #{@path}" unless doc.is_a?(Hash)
        raise Integrate::Errors::SpecInvalid, "Missing 'paths' in #{@path}" unless doc['paths'].is_a?(Hash)

        doc
      rescue Psych::SyntaxError => e
        raise Integrate::Errors::SpecInvalid, "YAML parse error at #{@path}: #{e.message}"
      end

      # ---- Info / servers -----------------------------------------------------

      def build_info(raw)
        title = raw['title'] || 'Unnamed Provider'
        slug  = slugify(title)
        Integrate::Ir::Info.new(
          title: title,
          provider_slug: slug,
          provider_class_name: "#{camelize(slug)}Service",
          version: raw['version'],
          description: raw['description'],
          contact_email: raw.dig('contact', 'email')
        )
      end

      def slugify(title)
        title.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').split('_').first || 'provider'
      end

      def camelize(slug)
        slug.split('_').map(&:capitalize).join
      end

      def build_servers(raw)
        raw = [{ 'url' => 'https://api.example.com', 'description' => 'default' }] if raw.empty?
        raw.map do |s|
          Integrate::Ir::Server.new(
            url: s.fetch('url'),
            description: s['description'],
            env_kind: env_kind_for(s['description'].to_s, s['url'].to_s)
          )
        end
      end

      def env_kind_for(description, url)
        text = "#{description} #{url}".downcase
        return :sandbox    if text.match?(/sandbox|staging|test|dev/)
        return :production if text.match?(/prod|live/)

        :unknown
      end

      # ---- Endpoints ----------------------------------------------------------

      def build_endpoints(doc)
        endpoints = []
        doc.fetch('paths', {}).each do |path, path_item|
          next unless path_item.is_a?(Hash)

          shared_params = (path_item['parameters'] || []).map { |p| @resolver.resolve(p) }
          path_item.slice(*HTTP_METHODS).each do |method, op|
            endpoints << build_endpoint(path, method, op, shared_params, doc)
          end
        end
        raise Integrate::Errors::SpecInvalid, 'No endpoints found in spec' if endpoints.empty?

        endpoints
      end

      def build_endpoint(path, method_str, op, shared_params, doc)
        op = @resolver.resolve(op)
        method = method_str.to_sym
        params = dedup_params(shared_params + (op['parameters'] || []).map { |p| @resolver.resolve(p) })
        req_body = build_request_body(op['requestBody'])

        Integrate::Ir::Endpoint.new(
          operation_id: op['operationId'] || fallback_operation_id(method_str, path),
          method: method,
          path: path,
          summary: op['summary'],
          description: op['description'],
          tags: Array(op['tags']),
          path_params: params_in(params, 'path'),
          query_params: params_in(params, 'query'),
          header_params: params_in(params, 'header'),
          request_body: req_body,
          responses: build_responses(op['responses'] || {}),
          security: op.key?('security') ? op['security'] : doc['security'],
          role: RoleClassifier.classify(
            method: method,
            path: path,
            tags: Array(op['tags']),
            request_body: op['requestBody']
          ),
          examples: []
        )
      end

      def fallback_operation_id(method, path)
        "#{method}_#{path}".downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
      end

      def dedup_params(params)
        seen = Set.new
        params.select { |p| seen.add?([p['name'], p['in']]) }
      end

      def params_in(params, location)
        params.select { |p| p['in'] == location }.map { |p| build_field_from_param(p, location) }
      end

      # ---- Request body / responses ------------------------------------------

      def build_request_body(raw)
        return nil unless raw

        raw = @resolver.resolve(raw)
        json = raw.dig('content', 'application/json')
        return nil unless json # only application/json bodies are supported

        schema_raw = @resolver.resolve(json['schema'] || {})
        Integrate::Ir::RequestBody.new(
          required: !!raw['required'],
          content_type: 'application/json',
          schema: build_schema(schema_raw),
          examples: extract_examples(json, owner: :request_body)
        )
      end

      def build_responses(raw)
        raw.each_with_object({}) do |(code, body), acc|
          body = @resolver.resolve(body)
          json = body.dig('content', 'application/json')
          schema = json && json['schema'] ? build_schema(@resolver.resolve(json['schema'])) : nil
          examples = json ? extract_examples(json, owner: :response, owner_code: code.to_s) : []
          headers = build_headers(body['headers'] || {})
          acc[code.to_s] = Integrate::Ir::Response.new(
            code: code.to_s,
            description: body['description'],
            content_type: json ? 'application/json' : nil,
            schema: schema,
            examples: examples,
            headers: headers
          )
        end
      end

      def build_headers(raw)
        raw.map do |name, header|
          header = @resolver.resolve(header)
          schema = header['schema'] || {}
          Integrate::Ir::Field.new(
            name: name, location: :header,
            type: schema['type'] || 'string', format: schema['format'],
            required: !!header['required'], description: header['description'],
            enum: schema['enum'], example: schema['example'], pattern: schema['pattern'],
            minimum: schema['minimum'], maximum: schema['maximum'],
            min_length: schema['minLength'], max_length: schema['maxLength'],
            role: :unknown, units: :unknown
          )
        end
      end

      # ---- Schema / fields ----------------------------------------------------

      def build_schema(raw)
        return nil unless raw

        raw = @resolver.resolve(raw)
        Integrate::Ir::Schema.new(
          type: raw['type'] || (raw['properties'] ? 'object' : 'string'),
          format: raw['format'],
          properties: build_properties(raw['properties'] || {}, raw['required'] || []),
          required: raw['required'] || [],
          items: raw['items'] ? build_schema(raw['items']) : nil,
          enum: raw['enum'],
          example: raw['example'],
          pattern: raw['pattern'],
          nullable: raw['nullable'],
          x_role: nil,
          raw: raw
        )
      end

      def build_properties(props, required_names)
        props.each_with_object({}) do |(name, raw), acc|
          raw = @resolver.resolve(raw)
          acc[name] = build_field_from_schema(name, raw, required_names.include?(name))
        end
      end

      def build_field_from_schema(name, raw, required)
        Integrate::Ir::Field.new(
          name: name, location: :body,
          type: raw['type'] || 'string', format: raw['format'],
          required: required, description: raw['description'],
          enum: raw['enum'], example: raw['example'], pattern: raw['pattern'],
          minimum: raw['minimum'], maximum: raw['maximum'],
          min_length: raw['minLength'], max_length: raw['maxLength'],
          role: :unknown, units: :unknown
        )
      end

      def build_field_from_param(param, location)
        schema = param['schema'] || {}
        Integrate::Ir::Field.new(
          name: param['name'], location: location.to_sym,
          type: schema['type'] || 'string', format: schema['format'],
          required: !!param['required'], description: param['description'],
          enum: schema['enum'], example: param['example'] || schema['example'], pattern: schema['pattern'],
          minimum: schema['minimum'], maximum: schema['maximum'],
          min_length: schema['minLength'], max_length: schema['maxLength'],
          role: :unknown, units: :unknown
        )
      end

      # ---- Examples ----------------------------------------------------------

      def extract_examples(json_node, owner:, owner_code: nil)
        list = []
        if json_node.key?('example')
          list << Integrate::Ir::Example.new(
            name: 'default', summary: nil, value: json_node['example'],
            owner: owner, owner_code: owner_code, synthetic: false
          )
        end
        (json_node['examples'] || {}).each do |name, body|
          body = @resolver.resolve(body)
          list << Integrate::Ir::Example.new(
            name: name.to_s, summary: body['summary'], value: body['value'],
            owner: owner, owner_code: owner_code, synthetic: false
          )
        end
        list
      end

      # ---- Security ----------------------------------------------------------

      def build_auth(doc)
        schemes = doc.dig('components', 'securitySchemes') || {}
        return nil if schemes.empty?

        # Pick the first scheme referenced by the document-level `security:`
        # (or the first defined scheme if none is declared).
        preferred = document_preferred_scheme(doc, schemes)
        name, raw = preferred || schemes.first
        build_auth_scheme(name, raw)
      end

      def document_preferred_scheme(doc, schemes)
        (doc['security'] || []).each do |req|
          req.each_key do |name|
            return [name, schemes[name]] if schemes.key?(name)
          end
        end
        nil
      end

      def build_auth_scheme(name, raw)
        raw = @resolver.resolve(raw)
        type = auth_type_for(raw)
        Integrate::Ir::AuthScheme.new(
          type: type,
          scheme_name: name,
          location: raw['in']&.to_sym,
          header_or_param_name: raw['name'],
          bearer_format: raw['bearerFormat'],
          oauth2_flow: nil,
          token_url: raw.dig('flows', 'clientCredentials', 'tokenUrl'),
          scopes: (raw.dig('flows', 'clientCredentials', 'scopes') || {}).keys,
          credentials_keys: credentials_keys_for(type)
        )
      end

      def auth_type_for(raw)
        case raw['type']
        when 'apiKey' then :api_key
        when 'http'   then raw['scheme']&.downcase == 'basic' ? :basic : :bearer
        when 'oauth2' then :oauth2
        else :api_key
        end
      end

      def credentials_keys_for(type)
        case type
        when :api_key then %w[api_key]
        when :bearer  then %w[access_token]
        when :basic   then %w[username password]
        when :oauth2  then %w[client_id client_secret]
        else %w[api_key]
        end
      end

      # ---- Webhooks -----------------------------------------------------------

      def build_webhooks(doc)
        collect_callbacks(doc).map { |ep_hash| build_webhook_spec(ep_hash) }
      end

      def collect_callbacks(doc)
        result = []
        doc.fetch('paths', {}).each do |path, path_item|
          next unless path_item.is_a?(Hash)

          path_item.slice(*HTTP_METHODS).each do |method, op|
            op = @resolver.resolve(op)
            tags = Array(op['tags'])
            next unless RoleClassifier.webhook?(path: path, tags: tags)

            result << { path: path, method: method, op: op }
          end
        end
        result
      end

      def build_webhook_spec(ep)
        headers = (ep[:op]['parameters'] || []).map { |p| @resolver.resolve(p) }.select { |p| p['in'] == 'header' }
        sig_header = headers.map { |h| h['name'] }.find { |n| n.to_s.match?(/(signature|sig)\z/i) }
        body_schema = @resolver.resolve(ep[:op].dig('requestBody', 'content', 'application/json', 'schema') || {})
        op_description = ep[:op]['description'].to_s

        algo = signature_algo_for(headers, op_description)
        # PayCloud picks the id field from `transfer_id`; NovaPay from `payout_id`.
        id_field = %w[payout_id transfer_id id].find { |f| body_schema.dig('properties', f) }

        Integrate::Ir::WebhookSpec.new(
          endpoint: nil, # linked later by Spec builder via operation_id lookup
          signature_header: sig_header,
          signature_algo: algo,
          signature_encoding: :hex,
          signature_secret_key: 'callback_secret',
          events: extract_events(body_schema),
          status_field_path: body_schema.dig('properties', 'status') ? ['status'] : [],
          id_field_path: id_field ? [id_field] : [],
          error_field_path: body_schema.dig('properties', 'error') ? %w[error code] : []
        )
      end

      def signature_algo_for(headers, op_description = '')
        desc = headers.map { |h| "#{h['description']} #{h['name']}" }.join(' ')
        combined = "#{desc} #{op_description}".downcase

        # Explicit SHA-* mentions win. SHA-512 checked first (more specific).
        return :hmac_sha512 if combined.include?('sha512') || combined.include?('sha-512')
        return :hmac_sha1   if combined.match?(/sha[-_ ]?1(?![0-9])/)
        return :hmac_sha256 if combined.include?('sha256') || combined.include?('sha-256')
        # Bare HMAC mention (algo unspecified) — assume SHA-256 (industry norm).
        return :hmac_sha256 if combined.include?('hmac')

        :unknown
      end

      def extract_events(schema)
        # Providers use either `event` (NovaPay) or `type` (PayCloud, Stripe-style)
        # as the event discriminator field. Try both.
        enum = schema.dig('properties', 'event', 'enum') ||
               schema.dig('properties', 'type', 'enum') || []
        enum.map(&:to_s)
      end

      # ---- Schemas ------------------------------------------------------------

      def build_schemas(doc)
        raw = doc.dig('components', 'schemas') || {}
        raw.each_with_object({}) do |(name, node), acc|
          acc[name] = build_schema(@resolver.resolve(node))
        end
      end
    end
  end
end
