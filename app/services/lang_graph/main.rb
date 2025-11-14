# frozen_string_literal: true

require "json"

begin
  require "langgraph_rb"
rescue LoadError => e
  warn "[LanggraphRbService] langgraph_rb not available: #{e.message}"
end

begin
  require "langgraph_rb/chat_openai"
rescue LoadError => e
  warn "[LanggraphRbService] langgraph_rb/chat_openai not available: #{e.message}"
end

module Services
  class LanggraphRbService
    class MemoryStore < LangGraphRB::Stores::InMemoryStore
      def save(thread_id, state, step_number, metadata = {})
        normalized_state = ensure_state_object(state)
        super(thread_id, normalized_state, step_number, metadata)
      end

      def load(thread_id, step_number = nil)
        checkpoint = super
        return checkpoint unless checkpoint

        checkpoint[:state] = ensure_state_object(checkpoint[:state])
        checkpoint
      end

      private

      def ensure_state_object(state)
        return state if state.nil? || state.respond_to?(:merge_delta)

        LangGraphRB::State.new(state)
      end
    end

    def initialize(graph: nil, store: nil)
      @graph = graph || init_lang_graph
      @store = store || init_store
    end

    def init_store
      MemoryStore.new
    end

    def init_lang_graph
      client = llm_client
      classifier_prompt = classify_system_prompt
      interpret_intent = method(:parse_intent_label)

      graph = LangGraphRB::Graph.new do
        # Nodes
        node :entry do |state, ctx|
          { session_id: ctx[:session_id], message: ctx[:message] }
        end

        llm_node :classify, llm_client: client, system_prompt: classifier_prompt do |state, ctx|
          user_input = state[:message].to_s.strip
          next { intent: :unknown } if user_input.empty?

          messages = [
            { role: "system", content: ctx[:system_prompt] },
            { role: "user", content: user_input }
          ]

          raw_response = ctx[:llm_client].call(messages)
          intent = interpret_intent.call(raw_response)

          { intent: intent }
        end

        node :search_products do |state|
          params  = Langgraph::Nlu.parse_search_params(state[:message])
          product = Langgraph::Catalog.search(**params)
          { params: params, found_product: product }
        end

        node :add_to_cart do |state|
          p = state[:found_product]
          cart = (state[:cart] || []) + [ { sku: p[:sku], name: p[:name], price: p[:price], qty: 1 } ]
          { cart: cart }
        end

        node :checkout do |state|
          total = state[:cart].map { |i| i[:price] * i[:qty] }.sum
          { order: (state[:order] || {}).merge(total: total) }
        end

        node :place_order do |state|
          t = state[:message].to_s.downcase
          payment =
            if t.include?("cod") || t.include?("ปลายทาง")
              "COD"
            elsif t.include?("โอน") || t.include?("bank transfer")
              "Bank Transfer"
            else
              state.dig(:order, :payment) || "COD"
            end
          total = state[:cart].to_a.map { |i| i[:price] * i[:qty] }.sum
          { order: (state[:order] || {}).merge(payment: payment, total: total) }
        end

        node :summary do |state|
          case state[:intent]
          when :search
            p = state[:found_product]
            msg = "แนะนำ: #{p[:name]} (#{p[:sku]}) ราคา #{p[:price]} บาท "\
                  "เพิ่มลงตะกร้าแล้ว รวมชำระ #{state.dig(:order, :total)} บาท "\
                  "ต้องการชำระแบบ COD หรือ โอนผ่านธนาคารคะ?"
          when :order
            pay  = state.dig(:order, :payment) || "COD"
            note = pay == "COD" ? "ชำระปลายทาง" : "โอนผ่านธนาคาร"
            msg  = "รับออเดอร์แล้วค่ะ วิธีชำระเงิน: #{pay} (#{note}) "\
                  "ยอดรวม #{state.dig(:order, :total) || 0} บาท"
          else
            msg = "ต้องการค้นหาสินค้าหรือสั่งซื้อคะ? เช่น 'หา เสื้อ สีแดง' หรือ 'สั่งซื้อ แบบ COD'"
          end
          { reply: msg }
        end

        # Flow
        set_entry_point :entry
        edge :entry, :classify

        conditional_edge :classify, ->(s) { s[:intent] }, {
          search: :search_products,
          order:  :place_order,
          unknown: :summary
        }

        edge :search_products, :add_to_cart
        edge :add_to_cart, :checkout
        edge :checkout, :summary

        edge :place_order, :summary

        # finish points
        set_finish_point :summary
      end

      graph.compile!
      graph
    end

    def run(session_id:, message:)
      thread_id = session_id.to_s
      context   = { session_id:, message: }

      if @store.load(thread_id) # มี checkpoint เก่า
        @graph.resume(thread_id, {}, context: context, store: @store)
      else
        @graph.invoke({}, context: context, store: @store, thread_id: thread_id)
      end
    end

    private

    def llm_client
      unless defined?(LangGraphRB::ChatOpenAI)
        raise "LangGraphRB::ChatOpenAI is unavailable. Ensure 'openai' gem is installed and required."
      end

      @llm_client ||= LangGraphRB::ChatOpenAI.new(
        model: "gpt-4o-mini-2024-07-18",
        temperature: 0.7,
        api_key: ENV["OPENAI_API_KEY"]
      )
    end

    def classify_system_prompt
      <<~PROMPT.strip
        คุณคือระบบจำแนกวัตถุประสงค์ของข้อความลูกค้าในร้านค้าออนไลน์ไทย
        ให้ตอบกลับด้วย JSON เดียวในรูปแบบ {"intent": "<intent>"}
        intents ที่อนุญาต:
        - "search": ลูกค้าถามหาสินค้า ค้นหา หรือสอบถามรายละเอียดสินค้า
        - "order": ลูกค้าต้องการสั่งซื้อ ชำระเงิน ยืนยันออเดอร์ หรือตามสถานะการสั่งซื้อ
        - "unknown": อื่น ๆ ที่ไม่เข้ากับสองประเภทแรก
        อย่าเพิ่มข้อความอื่นนอกจาก JSON ดังกล่าว
      PROMPT
    end

    def parse_intent_label(raw_response)
      payload =
        case raw_response
        when Hash
          raw_response[:intent] || raw_response["intent"] || raw_response[:content] || raw_response["content"]
        else
          raw_response
        end

      text = payload.to_s.strip
      begin
        parsed = JSON.parse(text)
        text = parsed["intent"] || parsed[:intent] || text
      rescue JSON::ParserError
        # keep original text
      end

      case text.to_s.strip.downcase
      when "search", "ค้นหา", "หา"
        :search
      when "order", "สั่งซื้อ", "สั่ง"
        :order
      else
        :unknown
      end
    end
  end
end
