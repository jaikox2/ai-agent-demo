require "net/http"
require "json"

class ImageEmbeddingService
  class Error < StandardError; end

  DEFAULT_TIMEOUT = 10

  def initialize(base_url: nil, open_timeout: DEFAULT_TIMEOUT, read_timeout: DEFAULT_TIMEOUT)
    @base_url = base_url || ENV.fetch("EMBEDDING_API_URL", "http://localhost:8000")
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def embed(text: nil)
    raise ArgumentError, "text must be provided" if text.blank?

    response = text_embed(text)

    vector = extract_vector(response)
    raise Error, "Vector not found in embedding response" if vector.blank?

    vector.map { |value| Float(value) }
  rescue JSON::ParserError => e
    raise Error, "Failed to parse embedding response: #{e.message}"
  rescue ArgumentError, TypeError => e
    raise Error, e.message
  end

  def embed_images(image_base64_list)
    list = Array(image_base64_list).compact
    raise ArgumentError, "image_base64_list must contain at least one image" if list.empty?

    response = perform_request(
      build_uri("/embed_images_b64"),
      { "images_b64" => list }
    )

    vectors = extract_vector_list(response)
    raise Error, "Vectors not found in embedding response" if vectors.blank?

    vectors.map do |vector|
      ensure_numeric_vector!(vector)
      vector.map { |value| Float(value) }
    end
  rescue JSON::ParserError => e
    raise Error, "Failed to parse embedding response: #{e.message}"
  end

  private

  attr_reader :base_url, :open_timeout, :read_timeout

  def build_uri(path)
    uri = URI.parse(base_url)
    uri.path = (uri.path.to_s.chomp("/") + path)
    uri
  end

  def perform_request(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.dump(payload)

    response = build_http(uri).request(request)
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "Embedding API request failed with status #{response.code}"
    end

    JSON.parse(response.body)
  rescue SocketError, Errno::ECONNREFUSED, Net::ReadTimeout, Net::OpenTimeout => e
    raise Error, "Embedding API request failed: #{e.message}"
  end

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout
    http
  end

  def extract_vector(response)
    return unless response.is_a?(Hash)

    response["vector"] ||
      response["embedding"] ||
      extract_from_data(response["data"]) ||
      extract_from_data(response["result"])
  end

  def extract_vector_list(response)
    return unless response.is_a?(Hash)

    vectors =
      response["embeddings"] || response[:embeddings]
    return vectors
  end

  def extract_from_data(data)
    case data
    when Array
      data.each do |item|
        next unless item.is_a?(Hash)

        vector = item["vector"] || item[:vector] || item["embedding"] || item[:embedding]
        return vector if vector.present?
      end
      nil
    when Hash
      data["vector"] || data[:vector] || data["embedding"] || data[:embedding]
    else
      nil
    end
  end

  def text_embed(text)
    perform_request(
      build_uri("/embed"),
      { "text" => text }
    )
  end

  def ensure_numeric_vector!(vector)
    unless vector.is_a?(Array) && vector.all? { |value| value.respond_to?(:to_f) }
      raise Error, "Invalid vector format in embedding response"
    end
  end
end
