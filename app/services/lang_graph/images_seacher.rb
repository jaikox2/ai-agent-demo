require "base64"
require "net/http"
require "uri"

class LangGraph::ImagesSeacher

  def initialize(account_id)
    @assistant = Langchain::Assistant.new(
      llm: llm,
      instructions: <<~PROMPT.strip,
        ช่วยแยก url จากข้อความ และ result เป็นรูปแบบ '{\"images\":[\"url_1\",\"url_2\"]}'
        ตัวอย่าง
         - {\"images\":[\"https://assets.page365.net/photos/original/363992/439389349.jpg?1744946533\",\"https://assets.page365.net/photos/original/363992/44444.jpg?44444\"]}
      PROMPT
      messages: []
    )
    @account_id = account_id
  end

  def run(content = "รูป https://assets.page365.net/photos/original/363992/439389349.jpg?1744946533")
    urls = @assistant.add_message_and_run!(content: content)
    parse_urls = JSON.parse(urls.last.content)["images"]
    images = build_base64_images_from_urls(parse_urls)
    @image_service = LangGraph::Tools::ImageService.new(@account_id, images)
    response = @image_service.run
    payload = format_response(response)
    payload = valid_response(payload)
    payload
  end

  private

  def valid_response(payload)
    p payload["score"]
    if payload && payload["score"] > 0.8
      payload
    else
      nil
    end
  end

  def format_response(response)
    if response["result"].present?
      response["result"].first["payload"].merge("score" => response["result"].first["score"])
    else
      {}
    end
  end

  def llm
    Langchain::LLM::OpenAI.new(
      api_key: ENV["OPENAI_API_KEY"],
      default_options: { temperature: 0.1, chat_model: "gpt-4o-mini-2024-07-18" }
    )
  end

  def build_base64_images_from_urls(urls)
    Array(urls).flatten.compact.each_with_object([]) do |url, memo|
      normalized_url = url.to_s.strip
      next if normalized_url.blank?

      base64 = encode_url_to_base64(normalized_url)
      memo << base64 if base64.present?
    end
  end

  def encode_url_to_base64(url, redirect_limit = 3)
    uri = URI.parse(url)
    response = Net::HTTP.get_response(uri)

    case response
    when Net::HTTPSuccess
      Base64.strict_encode64(response.body)
    when Net::HTTPRedirection
      raise ArgumentError, "Too many redirects while fetching image" if redirect_limit <= 0

      location = response["location"].to_s
      return if location.blank?

      encode_url_to_base64(URI.join(uri, location).to_s, redirect_limit - 1)
    else
      nil
    end
  rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error
    nil
  end
end
