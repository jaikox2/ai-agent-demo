# frozen_string_literal: true

require "json"

begin
  require "langgraph_rb"
rescue LoadError => e
  warn "[LanggraphRbService] langgraph_rb not available: #{e.message}"
end

module LangGraph
  class Main
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
      graph = LangGraphRB::Graph.new do
        # Nodes
        node :entry do |state, ctx|
          { session_id: ctx[:session_id], message: ctx[:message] }
        end

        node :classify do |state, ctx|
          user_input = state[:message].to_s.strip
          next { intent: :unknown } if user_input.empty?

          agent = ClassifyAgent.new([])
          messages = agent.add_message_and_run!(content: user_input)

          raw = messages.last.content
          normalized = raw.gsub("'", '"')
          parsed = JSON.parse(normalized)

          { intent: parsed["intent"] }
        end

        node :search_products_by_images do |state|
          product  = LangGraph::ImagesSeacher.new(state[:account_id]).run(state[:message])
          { found_product: product }
        end

        node :search_products_by_text do |state|
          if state[:images].present?
            params  = LangGraph::ImagesSeacher.new(state[:account_id]).run(state[:message])
            { params: params, found_product: params }
          else
            { params: nil, found_product: nil }
          end
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
          search_products_by_images: :search_products_by_images,
          search_products_by_text:  :search_products_by_text,
          unknown: :summary
        }

        edge :search_products_by_images, :summary
        edge :search_products_by_text, :summary

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
  end
end
