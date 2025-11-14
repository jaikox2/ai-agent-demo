# frozen_string_literal: true

require "json"
module LangGraph
  class Tools::TextService
    extend Langchain::ToolDefinition
    define_function :search_products, description: "Search product: list or search products by name." do
      property :query,
               type: "string",
               description: "Optional text to match against product name.",
               required: false
    end

    VECTOR_NAMES = %w[image text].freeze

    def initialize(account_id)
      @account_id = account_id
    end

    def search_products(query: nil)
      p "Tools::TextService_________debug_query: #{query}"
      results = []
      limit = 20
      @vector = nil

      if @vector.blank? && query.present?
        begin
          text_vector = embed_query_vector(query)
          @vector = build_named_search_vector("text", text_vector)
        rescue ArgumentError => e
          return results
        end
      end

      normalized_query = normalize_query(query)
      if @vector.blank?
        tool_response(
        content: {
          query: normalized_query,
          count: results.size,
          products: results
        }.to_json
      )
      end
      response = qdrant_service.search(vector: @vector, limit: limit, filter: nil)

      tool_response(
        content: {
          query: normalized_query,
          count: Array(response["result"]).size,
          products: format_search_results(response)
        }.to_json
      )
    end

    private

    attr_reader :products

    def embed_query_vector(text)
      return if text.blank?

      image_embedding_service.embed(text: text)
    rescue ImageEmbeddingService::Error => e
      raise ArgumentError, "Query embedding failed: #{e.message}"
    end

    def normalize_query(query)
      normalized = query.to_s.strip.downcase
      normalized.empty? ? nil : normalized
    end

    def image_embedding_service
      @image_embedding_service ||= ImageEmbeddingService.new
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

    def qdrant_service
      @qdrant_service ||= ProductsQdrantService.new(account_id: @account_id)
    end
  end
end
