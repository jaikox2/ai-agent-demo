class SummarizeAgent

  def initialize(messages, product)
    @assistant = Langchain::Assistant.new(
      llm: llm,
      instructions: <<~PROMPT.strip,
        คุณคือระบบตอบกลับลูกค้าจากการที่ลูกค้าพยายามค้นหาสินค้าในร้านค้า
        ให้ตอบกลับด้วยรความสุภาพและกระชับ และนำเสนอสินค้าที่ตรงกับความต้องการของลูกค้าเหล่านี้
        #{product[:name]}, #{product[:description]}
      PROMPT
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
# example
# agent = SummaryAgent.new([], { name: "เสื้อเชิ้ตลายทาง", description: "เสื้อเชิ้ตลายทางสีฟ้า ขนาด M ทำจากผ้าฝ้ายคุณภาพดี" })
# messages = agent.add_message_and_run!(content: "ต้องการสั่งซื้อเสื้อเชิ้ตลายทาง")
