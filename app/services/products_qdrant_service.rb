require "qdrant"
require "json"

class ProductsQdrantService
  VECTOR_NAMES = %w[image text].freeze
  VECTOR_DISTANCE = "Cosine".freeze
  DEFAULT_VECTOR_DIMENSION = begin
    env_dimension =
      ENV["QDRANT_VECTOR_DIMENSION"] ||
      ENV["EMBEDDING_VECTOR_DIMENSION"]

    parsed = env_dimension.to_i if env_dimension && !env_dimension.strip.empty?
    parsed = 512 if parsed.nil? || parsed <= 0
    parsed
  end

  class NotFoundError < StandardError; end
  class DimensionMismatchError < StandardError
    attr_reader :expected, :actual

    def initialize(expected:, actual:)
      @expected = expected
      @actual = actual
      super("Vector dimension mismatch (expected #{expected}, got #{actual})")
    end
  end

  def initialize(account_id:, client: nil)
    @account_id = normalize_account_id(account_id)
    @client = client || Qdrant::Client.new(
      url: qdrant_url,
      api_key: qdrant_api_key,
      raise_error: true
    )
    @collection_checked = false
    @vector_dimension = parse_configured_vector_dimension
  end

  def ensure_collection!(vector_size: nil)
    return if @collection_checked

    update_vector_dimension(vector_size)

    collections = client.collections.list
    names = Array(collections.dig("result", "collections")).map { |item| item["name"] }
    unless names.include?(collection_name)
      client.collections.create(
        collection_name: collection_name,
        vectors: collection_vectors_config
      )
    else
      existing_dimension = fetch_collection_vector_dimension
      if existing_dimension
        @vector_dimension = existing_dimension
        validate_dimension_match!(vector_size, existing_dimension)
      end
    end

    @collection_checked = true
  end

  def validate_vector!(vector)
    case vector
    when Hash
      if vector_search_payload?(vector)
        values = vector_payload_values(vector)
        ensure_vector_array!(values)
      else
        ensure_multi_vector_payload!(vector)
      end
    else
      ensure_vector_array!(vector)
    end
  end

  def search(vector:, limit:, filter: nil)
    ensure_collection!(vector_size: determine_vector_size(vector))
    validate_vector!(vector)
    merged_filter = combine_filters(filter)

    with_qdrant_error_handling do
      client.points.search(
        collection_name: collection_name,
        vector: vector,
        limit: limit,
        with_payload: true,
        with_vector: true,
        filter: merged_filter
      )
    end
  end

  def scroll(limit:, offset:, filter:)
    ensure_collection!
    merged_filter = combine_filters(filter)

    with_qdrant_error_handling do
      client.points.scroll(
        collection_name: collection_name,
        limit: limit,
        offset: offset,
        filter: merged_filter,
        with_payload: true,
        with_vector: true
      )
    end
  end

  def upsert(id:, payload:, vector:)
    ensure_collection!(vector_size: determine_vector_size(vector))
    validate_vector!(vector)
    normalized_id = normalize_id(id)
    normalized_payload = ensure_payload_account(payload)

    with_qdrant_error_handling do
      client.points.upsert(
        collection_name: collection_name,
        points: [
          {
            id: normalized_id,
            vector: vector,
            payload: normalized_payload
          }
        ]
      )
    end

    {
      "id" => normalized_id,
      "payload" => normalized_payload,
      "vector" => vector
    }
  end

  def delete(id:)
    ensure_collection!

    with_qdrant_error_handling do
      client.points.delete(
        collection_name: collection_name,
        points: [normalize_id(id)]
      )
    end
  end

  def vector_dimension
    @vector_dimension ||= fetch_collection_vector_dimension || DEFAULT_VECTOR_DIMENSION
  end

  def collection_name
    base_collection_name
  end

  def find(id:)
    ensure_collection!

    normalized_id = normalize_id(id)

    response = client.points.list(
      collection_name: collection_name,
      ids: [normalized_id],
      with_payload: true,
      with_vector: true
    )

    points = extract_points(response)
    points.find do |point|
      point["id"].to_s == normalized_id.to_s && payload_account_match?(point["payload"])
    end
  end

  def find!(id:)
    normalized_id = normalize_id(id)
    find(id: normalized_id) || raise(NotFoundError, "Product not found")
  end

  private

  attr_reader :client, :account_id

  def collection_vectors_config
    VECTOR_NAMES.each_with_object({}) do |name, config|
      config[name] = {
        size: vector_dimension,
        distance: VECTOR_DISTANCE
      }
    end
  end

  def validate_dimension_match!(vector_size, existing_dimension)
    return if vector_size.nil?

    numeric_size = vector_size.to_i
    return if numeric_size <= 0
    return if numeric_size == existing_dimension.to_i

    raise ArgumentError,
          "Qdrant collection '#{collection_name}' is configured for vectors of dimension " \
          "#{existing_dimension}, but received vector size #{vector_size}. " \
          "Please recreate the collection or update QDRANT_VECTOR_DIMENSION to match."
  end

  def determine_vector_size(vector)
    case vector
    when Hash
      if vector.key?("vector") || vector.key?(:vector)
        values = vector["vector"] || vector[:vector]
        return values.size if values.is_a?(Array)
      end

      VECTOR_NAMES.each do |name|
        values = vector[name] || vector[name.to_sym]
        return values.size if values.is_a?(Array)
      end
      nil
    when Array
      vector.size
    else
      nil
    end
  end

  def vector_search_payload?(vector)
    vector.key?("name") || vector.key?(:name) || vector.key?("vector") || vector.key?(:vector)
  end

  def vector_payload_values(vector)
    vector["vector"] || vector[:vector]
  end

  def ensure_multi_vector_payload!(vectors)
    VECTOR_NAMES.each do |name|
      values = vectors[name] || vectors[name.to_sym]
      raise ArgumentError, "Vector '#{name}' must be provided" if values.nil?

      ensure_vector_array!(values)
    end
  end

  def ensure_vector_array!(vector)
    unless vector.is_a?(Array)
      raise ArgumentError, "Vector must be an array"
    end

    update_vector_dimension(vector.size)

    unless vector.size == vector_dimension
      raise ArgumentError, "Vector must have #{vector_dimension} dimensions"
    end
  end

  def update_vector_dimension(size)
    return unless size.respond_to?(:to_i)

    numeric_size = size.to_i
    return unless numeric_size.positive?

    @vector_dimension = numeric_size
  end

  def with_qdrant_error_handling
    yield
  rescue Faraday::BadRequestError => e
    raise parse_qdrant_error(e)
  end

  def parse_qdrant_error(error)
    message = extract_error_message(error)
    if (match = message&.match(/expected dim:\s*(\d+),\s*got\s*(\d+)/i))
      expected = match[1].to_i
      actual = match[2].to_i
      return DimensionMismatchError.new(expected: expected, actual: actual)
    end

    error
  end

  def extract_error_message(error)
    return error.message unless error.respond_to?(:response)

    response = error.response
    body = response && response[:body]
    parsed =
      case body
      when String
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          body
        end
      else
        body
      end

    if parsed.is_a?(Hash)
      parsed.dig("status", "error") ||
        parsed["message"] ||
        parsed["error"]
    elsif parsed
      parsed.to_s
    else
      error.message
    end
  end

  def parse_configured_vector_dimension
    value = ENV["QDRANT_VECTOR_DIMENSION"]
    return unless value

    numeric_value = value.to_i
    numeric_value.positive? ? numeric_value : nil
  end

  def fetch_collection_vector_dimension
    response = client.collections.get(collection_name: collection_name)
    vectors = response.dig("result", "config", "params", "vectors")
    ensure_required_vector_config!(vectors)

    size = extract_dimension_from_vectors_config(vectors)
    size && size.to_i.positive? ? size.to_i : nil
  rescue Faraday::Error
    nil
  end

  def ensure_required_vector_config!(vectors)
    return if vectors.nil?

    unless vectors.is_a?(Hash)
      raise ArgumentError,
            "Qdrant collection '#{collection_name}' returned an unexpected vectors configuration. " \
            "Please recreate the collection with vectors: #{VECTOR_NAMES.join(', ')}."
    end

    if vectors["size"] || vectors[:size]
      raise ArgumentError,
            "Qdrant collection '#{collection_name}' must be recreated with named vectors " \
            "(#{VECTOR_NAMES.join(', ')}) to store both representations."
    end

    missing = VECTOR_NAMES.reject do |name|
      entry = vectors[name] || vectors[name.to_sym]
      entry.is_a?(Hash) && (entry["size"] || entry[:size]).to_i.positive?
    end

    return if missing.empty?

    raise ArgumentError,
          "Qdrant collection '#{collection_name}' is missing vector(s): #{missing.join(', ')}. " \
          "Please recreate the collection with vectors: #{VECTOR_NAMES.join(', ')}."
  end

  def extract_dimension_from_vectors_config(vectors)
    return unless vectors.is_a?(Hash)

    direct = vectors["size"] || vectors[:size]
    return direct if direct

    VECTOR_NAMES.each do |name|
      entry = vectors[name] || vectors[name.to_sym]
      next unless entry.is_a?(Hash)

      size = entry["size"] || entry[:size]
      return size if size
    end

    nil
  end

  def normalize_id(id)
    value = id.is_a?(Array) ? id.first : id
    value = value.to_s if value
    raise ArgumentError, "ID cannot be blank" if value.nil? || value.empty?

    value
  end

  def extract_points(response)
    return [] unless response.is_a?(Hash)

    result = response["result"]
    points =
      case result
      when Hash
        result["points"]
      when Array
        result
      else
        nil
      end

    Array(points)
  end

  def ensure_payload_account(payload)
    data = (payload || {}).transform_keys(&:to_s)
    data["account_id"] = account_id
    data
  end

  def payload_account_match?(payload)
    data =
      case payload
      when Hash
        payload
      else
        {}
      end

    value = data["account_id"] || data[:account_id]
    value.to_s == account_id
  end

  def combine_filters(filter)
    condition = account_condition
    return filter unless condition

    return { must: [condition] } if filter.blank?

    { must: [condition, filter] }
  end

  def account_condition
    {
      key: "account_id",
      match: {
        value: account_id
      }
    }
  end

  def base_collection_name
    ENV.fetch("QDRANT_COLLECTION_NAME", "products")
  end

  def qdrant_url
    ENV.fetch("QDRANT_URL", "http://localhost:6333")
  end

  def qdrant_api_key
    ENV["QDRANT_API_KEY"]
  end

  def normalize_account_id(value)
    str = value.to_s.strip
    raise ArgumentError, "account_id cannot be blank" if str.empty?

    str.gsub(/[^a-zA-Z0-9_-]/, "_")
  end
end
