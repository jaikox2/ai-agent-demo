require "securerandom"
require "base64"

class ProductsController < ApplicationController
  before_action :require_account_id
  before_action :ensure_collection_ready

  VECTOR_NAMES = %w[image text].freeze
  DEFAULT_VECTOR_NAME = "text"
  REQUIRED_CREATE_FIELDS = %w[name price stock details images].freeze

  def index
    limit = parse_limit(params[:limit], default: 20)
    query = params[:query]
    image_sources = collect_image_sources(params[:images])
    vector = nil

    if image_sources.present?
      begin
        image_vector = embed_image_vector(image_sources)
        vector = build_named_search_vector("image", image_vector)
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity and return
      end
    end

    if vector.blank? && query.present?
      begin
        text_vector = embed_query_vector(query)
        vector = build_named_search_vector("text", text_vector)
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity and return
      end
    end

    if vector.blank?
      render json: { error: "images or query is required for search" }, status: :unprocessable_entity and return
    end

    response = qdrant_service.search(vector: vector, limit: limit, filter: nil)

    render json: {
      products: format_search_results(response),
      count: Array(response["result"]).size
    }, status: :ok
  rescue StandardError => e
    render_error(e)
  end

  def create
    attributes = sanitized_product_attributes
    attributes = normalize_payload(attributes)
    id = params[:id].presence&.to_s || SecureRandom.uuid
    attributes["account_id"] = account_id
    image_sources = collect_image_sources(
      attributes["images"],
      params.dig(:product, :images)
    )
    vector = vector_from_attributes(attributes, image_sources: image_sources)

    point = qdrant_service.upsert(id: id, payload: attributes, vector: vector)
    formatted = format_point(point)

    render json: { id: point["id"], product: formatted }, status: :created
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    render_error(e)
  end

  def update
    id = params[:id].to_s
    point = qdrant_service.find!(id: id)
    current_payload = (point["payload"] || {}).transform_keys(&:to_s)
    merged_attributes = current_payload.merge(sanitized_product_attributes)
    merged_attributes = normalize_payload(merged_attributes)
    merged_attributes["account_id"] = account_id
    image_sources = collect_image_sources(
      merged_attributes["images"],
      params.dig(:product, :images)
    )
    vector = vector_from_attributes(merged_attributes, image_sources: image_sources)

    point = qdrant_service.upsert(id: id, payload: merged_attributes, vector: vector)
    formatted = format_point(point)

    render json: { id: point["id"], product: formatted }, status: :ok
  rescue ProductsQdrantService::NotFoundError => e
    render json: { error: e.message }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    render_error(e)
  end

  def destroy
    id = params[:id].to_s
    qdrant_service.find!(id: id) # ensure it exists
    qdrant_service.delete(id: id)

    head :no_content
  rescue ProductsQdrantService::NotFoundError => e
    render json: { error: e.message }, status: :not_found
  rescue StandardError => e
    render_error(e)
  end

  private

  def ensure_collection_ready
    qdrant_service.ensure_collection!
  end

  def format_search_results(response)
    results = Array(response["result"])
    results.map do |point|
      format_point(point).merge("score" => point["score"])
    end
  end

  def format_point(point)
    payload = normalize_point_payload(point["payload"])
    {
      "id" => point["id"],
      "name" => payload["name"],
      "price" => payload["price"],
      "stock" => payload["stock"],
      "details" => payload["details"]
    }.compact
  end

  def sanitized_product_attributes
    attributes = product_params.to_h
    attributes.delete("vector")

    if action_name == "create"
      missing = REQUIRED_CREATE_FIELDS.reject { |field| attributes.key?(field) }
      raise ArgumentError, "Missing required fields: #{missing.join(', ')}" if missing.any?
    end

    attributes["price"] = attributes["price"].to_f if attributes.key?("price")
    attributes["stock"] = attributes["stock"].to_i if attributes.key?("stock")

    if attributes.key?("images")
      images = Array(attributes["images"]).flatten.compact.reject(&:blank?)
      attributes["images"] = images
    end

    attributes
  end

  def vector_from_attributes(attributes, image_sources:)
    vectors = {}

    vectors["image"] = embed_image_vector(image_sources)
    vectors["text"] = embed_text_vector(attributes)
    if vectors["image"].blank? && vectors["text"].blank?
      raise ArgumentError, "Unable to generate vectors from provided images or text"
    end
    vectors["image"] ||= vectors["text"]
    vectors["text"] ||= vectors["image"]

    ensure_required_vectors!(vectors)
    vectors
  end

  def extract_vector(raw_vector)
    return if raw_vector.blank?

    array =
      case raw_vector
      when Array
        raw_vector
      when ActionController::Parameters
        raw_vector.to_unsafe_h.values
      when Hash
        hash = raw_vector.to_h
        candidate = hash["vector"] || hash[:vector] || hash["values"] || hash[:values]
        return extract_vector(candidate) if candidate.present?

        return extract_vector(hash.values.first)
      when String
        raw_vector.split(",")
      else
        [raw_vector]
      end

    raise ArgumentError, "Vector must be an array of numbers" if array.nil?

    array.map! { |value| Float(value) }
  rescue ArgumentError, TypeError
    raise ArgumentError, "Vector must be an array of numbers"
  end

  def parse_limit(value, default:)
    Integer(value || default)
  rescue ArgumentError, TypeError
    default
  end

  def normalize_payload(payload)
    normalized = payload.transform_keys(&:to_s)
    normalized["price"] = normalized["price"].to_f if normalized.key?("price") && !normalized["price"].nil?
    normalized["stock"] = normalized["stock"].to_i if normalized.key?("stock") && !normalized["stock"].nil?
    if normalized.key?("images")
      normalized["images"] = Array(normalized["images"]).flatten.compact.reject(&:blank?)
    end
    normalized
  end

  def normalize_point_payload(raw_payload)
    case raw_payload
    when Hash
      raw_payload.transform_keys(&:to_s)
    when Array
      raw_payload.each_with_object({}) do |item, memo|
        next unless item.is_a?(Hash)

        memo.merge!(item.transform_keys(&:to_s))
      end
    else
      {}
    end
  end

  def collect_image_sources(*inputs)
    inputs.compact.flat_map { |input| normalize_image_value(input) }.compact
  end

  def normalize_image_value(value)
    case value
    when Array
      value.flat_map { |item| normalize_image_value(item) }
    when ActionController::Parameters
      normalize_image_value(value.to_unsafe_h)
    when ActionDispatch::Http::UploadedFile
      encoded = encode_uploaded_file(value)
      encoded.present? ? [encoded] : []
    when Hash
      file = extract_file_from_hash(value)
      return normalize_image_value(file) if file

      data = value.respond_to?(:symbolize_keys) ? value.symbolize_keys : value.transform_keys(&:to_sym)
      base64 = data[:image_base64] || data[:base64] || data[:data]
      normalize_image_value(base64)
    when String
      str = value.to_s.strip
      return [] if str.blank?

      str.start_with?("data:") ? [str.split(",", 2).last.presence].compact : [str]
    else
      []
    end
  end

  def embed_image_vector(image_sources)
    sources = Array(image_sources).compact
    return if sources.blank?

    vectors = image_embedding_service.embed_images(sources)
    return vectors.first if vectors.size == 1

    averaged = average_vectors(vectors)
    raise ArgumentError, "Image embedding failed: empty response" if averaged.blank?

    averaged
  rescue ImageEmbeddingService::Error => e
    raise ArgumentError, "Image embedding failed: #{e.message}"
  end

  def average_vectors(vectors)
    return if vectors.blank?

    dimension = vectors.first&.size
    return if dimension.nil? || dimension.zero?

    sums = Array.new(dimension, 0.0)
    vectors.each do |vector|
      raise ArgumentError, "Image embeddings returned inconsistent dimensions" if vector.size != dimension

      vector.each_with_index { |value, index| sums[index] += value.to_f }
    end

    sums.map { |sum| sum / vectors.size }
  end

  def embed_text_vector(attributes)
    text = build_text_embedding_input(attributes)
    return if text.blank?

    image_embedding_service.embed(text: text)
  rescue ImageEmbeddingService::Error => e
    raise ArgumentError, "Text embedding failed: #{e.message}"
  end

  def embed_query_vector(text)
    return if text.blank?

    image_embedding_service.embed(text: text)
  rescue ImageEmbeddingService::Error => e
    raise ArgumentError, "Query embedding failed: #{e.message}"
  end

  def build_text_embedding_input(attributes)
    return if attributes.blank?

    data =
      case attributes
      when ActionController::Parameters
        attributes.to_unsafe_h
      when Hash
        attributes
      else
        attributes.respond_to?(:to_h) ? attributes.to_h : {}
      end

    name = data["name"] || data[:name]
    details = data["details"] || data[:details]
    parts = [name, details].map { |value| value.to_s.strip }.reject(&:blank?)

    return if parts.empty?

    parts.join("\n\n")
  end

  def build_named_search_vector(name, vector)
    return if vector.blank?

    normalized_name = normalize_vector_name(name) || DEFAULT_VECTOR_NAME
    { "name" => normalized_name, "vector" => vector }
  end

  def normalize_vector_name(value)
    return if value.blank?

    str = value.to_s.strip.downcase
    return str if VECTOR_NAMES.include?(str)

    nil
  end

  def ensure_required_vectors!(vectors)
    missing = VECTOR_NAMES.reject { |name| vectors[name].present? }
    raise ArgumentError, "Unable to generate vectors: #{missing.join(', ')}" if missing.any?
  end

  def require_account_id
    return if account_id.present?

    render json: { error: "account_id is required" }, status: :unprocessable_entity
    throw :abort
  end

  def account_id
    @account_id ||= begin
      value = params[:account_id].presence || params.dig(:product, :account_id).presence
      value&.to_s
    end
  end

  def qdrant_service
    @qdrant_service ||= ProductsQdrantService.new(account_id: account_id)
  end

  def image_embedding_service
    @image_embedding_service ||= ImageEmbeddingService.new
  end

  def encode_uploaded_file(file)
    return unless file.respond_to?(:read)

    data = file.read
    file.rewind if file.respond_to?(:rewind)

    Base64.strict_encode64(data) if data.present?
  rescue StandardError
    nil
  end

  def extract_file_from_hash(hash)
    data = hash.respond_to?(:symbolize_keys) ? hash.symbolize_keys : hash.dup
    file = data[:file] || data[:image] || data[:upload] || data[:tempfile]
    file || data[:io]
  end

  def product_params
    product = params.require(:product)
    permitted = product.permit(
      :name,
      :price,
      :stock,
      :details,
      images: [],
      vector: {}
    )
    permitted[:vector] = product[:vector] if product.key?(:vector)
    permitted
  end

  def render_error(error)
    Rails.logger.error("[ProductsController] #{error.class}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n")) if error.backtrace

    case error
    when ProductsQdrantService::DimensionMismatchError
      render json: dimension_mismatch_response(error), status: :unprocessable_entity
    when Faraday::Error
      render json: { error: "Qdrant request failed", detail: error.message }, status: :bad_gateway
    else
      render json: { error: "Unexpected error", detail: error.message }, status: :internal_server_error
    end
  end

  def dimension_mismatch_response(error)
    {
      error: "Vector dimension mismatch",
      detail: "Qdrant collection '#{qdrant_service.collection_name}' expects "\
              "#{error.expected} dimensions but received #{error.actual}. "\
              "Recreate the collection with the correct vector size or set "\
              "QDRANT_VECTOR_DIMENSION / EMBEDDING_VECTOR_DIMENSION accordingly."
    }
  end
end
