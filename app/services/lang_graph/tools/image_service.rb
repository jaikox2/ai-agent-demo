class LangGraph::Tools::ImageService

  def initialize(account_id, image_sources)
    @image_sources = image_sources
    @account_id = account_id
    @limit = 1
  end

  def run
    image_vector = embed_image_vector(@image_sources)
    vector = build_named_search_vector("image", image_vector)

    response = qdrant_service.search(vector: vector, limit: @limit, filter: nil)
    response
  end

  def qdrant_service
    @qdrant_service ||= ProductsQdrantService.new(account_id: @account_id)
  end

  def image_embedding_service
    @image_embedding_service ||= ImageEmbeddingService.new
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

  def build_named_search_vector(name, vector)
    return if vector.blank?
    { "name" => name, "vector" => vector }
  end
end
