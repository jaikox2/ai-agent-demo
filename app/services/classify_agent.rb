class ClassifyAgent

  def initialize(messages)
    @assistant = Langchain::Assistant.new(
      llm: llm,
      instructions: <<~PROMPT.strip,
        คุณคือระบบจำแนกวัตถุประสงค์ของข้อความลูกค้าในร้านค้าออนไลน์ไทย
        ให้ตอบกลับด้วย JSON เดียวในรูปแบบ {'intent': '<intent>'}
        intents ที่อนุญาต:
        - 'search_products_by_images':
            ใช้เฉพาะเมื่อข้อความมี URL ภาพ (ลงท้าย .jpg/.jpeg/.png/.gif ฯลฯ), data URI base64, หรืออธิบายชัดเจนว่ามีการส่ง “รูป/ภาพ” เพื่อให้ร้านช่วยค้นหา
        - 'search_products_by_text':
            ใช้เมื่อข้อความเป็นการบรรยายความต้องการด้วยตัวอักษร เช่น “มีเสื้อเชิ้ตลายทางไหม”
        - 'other':
            ใช้เมื่อข้อความไม่เกี่ยวกับการค้นหาสินค้า หรือระบบไม่มั่นใจ/ข้อมูลไม่พอ
        ขั้นตอน:
        1. ตรวจว่ามีสัญญาณของภาพหรือไม่ (url ภาพ, base64, คำว่า รูป/ภาพ)
        2. หากไม่มี ให้ดูว่าเป็นการค้นหาด้วยข้อความหรือเรื่องอื่น
        3. สร้าง JSON เดียวตามรูปแบบที่กำหนด ห้ามเพิ่มข้อความอื่นหรือคอมเมนต์
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
# agent = ClassifyAgent.new([])
# messages = agent.add_message_and_run!(content: "ต้องการสั่งซื้อเสื้อสีแดง")
