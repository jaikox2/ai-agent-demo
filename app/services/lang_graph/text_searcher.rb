module LangGraph
  class TextSearcher
    def initialize(account_id, content, messages = [])
      @account_id = account_id
      @content = content
      @assistant = Langchain::Assistant.new(
        llm: llm,
        instructions: <<~PROMPT.strip,
        You are a friendly Thai-speaking shop assistant for a search products.
        Use the LangGraph::Tools::TextService tool whenever a question involves products, inventory, price, or comparisons. The tool queries Qdrant; pass it a concise Thai or English search phrase and summarize the returned items in Thai. If no matches are returned, explain that nothing was found and suggest alternative search terms.
        แสดง content ภาษาไทยเท่านั้น
        แสดง product ละ 1 บรรทัด
        ตัวอย่าง
         - {"name"=>"เสื้อ", "price"=>200.0, "stock"=>2, "details"=>"เสื้อสีขาว size L"}
        PROMPT
        tools: [ LangGraph::Tools::TextService.new(account_id) ],
        messages: messages
      )
    end

    def add_message_and_run!
      @assistant.add_message_and_run!(content: @content)
    end

    private

    def llm
      Langchain::LLM::OpenAI.new(
        api_key: ENV["OPENAI_API_KEY"],
        default_options: { temperature: 0.7, chat_model: "gpt-4o-mini-2024-07-18" }
      )
    end
  end
end
