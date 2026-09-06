# frozen_string_literal: true

# Intermediate Representation — provider-agnostic data classes that sit between
# the OpenAPI parser and the generators. All classes are Ruby 3.2 `Data.define`
# structs (immutable, value-equality). Enum-like constants live in the module
# body so that the parser can reference known symbols.
#
# See docs/analysis/ir_schema.md for the authoritative specification.
module Integrate
  module Ir
    # ---- Enum-like constants -------------------------------------------------

    ENDPOINT_ROLES = %i[create status cancel balance callback unknown].freeze

    HTTP_METHODS = %i[get post put patch delete head options trace].freeze

    AUTH_TYPES = %i[api_key bearer basic oauth2].freeze

    AUTH_LOCATIONS = %i[header query cookie].freeze

    SIGNATURE_ALGOS = %i[
      hmac_sha256 hmac_sha512 hmac_sha1 rsa_sha256
      timestamped_hmac_sha256 unknown
    ].freeze

    SIGNATURE_ENCODINGS = %i[hex base64 unknown].freeze

    ENV_KINDS = %i[sandbox production unknown].freeze

    # ---- Root ----------------------------------------------------------------

    Spec = Data.define(
      :info, :servers, :endpoints, :auth, :webhooks, :schemas,
      :raw_source, :openapi_version
    )

    # ---- Meta ----------------------------------------------------------------

    Info = Data.define(
      :title, :provider_slug, :provider_class_name,
      :version, :description, :contact_email
    )

    Server = Data.define(:url, :description, :env_kind)

    # ---- Endpoint / body / response -----------------------------------------

    Endpoint = Data.define(
      :operation_id, :method, :path, :summary, :description, :tags,
      :path_params, :query_params, :header_params,
      :request_body, :responses, :security, :role, :examples
    )

    RequestBody = Data.define(:required, :content_type, :schema, :examples)

    Response = Data.define(
      :code, :description, :content_type, :schema, :examples, :headers
    )

    Schema = Data.define(
      :type, :format, :properties, :required, :items, :enum,
      :example, :pattern, :nullable, :x_role, :raw
    )

    Field = Data.define(
      :name, :location, :type, :format, :required, :description,
      :enum, :example, :pattern,
      :minimum, :maximum, :min_length, :max_length,
      :role, :units
    )

    # ---- Auth ----------------------------------------------------------------

    AuthScheme = Data.define(
      :type, :scheme_name, :location, :header_or_param_name,
      :bearer_format, :oauth2_flow, :token_url, :scopes,
      :credentials_keys
    )

    # ---- Webhook -------------------------------------------------------------

    WebhookSpec = Data.define(
      :endpoint, :signature_header, :signature_algo, :signature_encoding,
      :signature_secret_key, :events,
      :status_field_path, :id_field_path, :error_field_path
    )

    # ---- Examples ------------------------------------------------------------

    Example = Data.define(
      :name, :summary, :value, :owner, :owner_code, :synthetic
    )
  end
end
