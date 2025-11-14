class MainController < ApplicationController
  def index
    message = params.require(:message)
    account_id = params.require(:account_id)
    session_id = params.require(:session_id)

    graph_main = LangGraph::Main.new
    result = graph_main.run(account_id:, session_id:, message:)

    render json: { result: result }, status: :ok
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end
end
