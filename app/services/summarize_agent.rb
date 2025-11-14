class SummarizeAgent

  def initialize(messages)
    @assistant = Langchain::Assistant.new(
      llm: llm,
      instructions: "
        คุณคือระบบตอบกลับลูกค้าจากการที่ลูกค้าพยายามค้นหาสินค้าในร้านค้า
        ให้ตอบกลับด้วยรความสุภาพและกระชับ และนำเสนอสินค้าที่ตรงกับความต้องการของลูกค้าเหล่านี้",
      tools: [],
      messages: messages
    )
  end

  def add_message_and_run!(content)
    @assistant.add_message_and_run!(content: content)
  end

  private

  def llm
    Langchain::LLM::OpenAI.new(
      api_key: ENV["OPENAI_API_KEY"],
      default_options: { temperature: 0.7, chat_model: "gpt-4o-mini-2024-07-18" }
    )
  end
end
