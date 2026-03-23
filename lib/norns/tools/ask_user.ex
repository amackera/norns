defmodule Norns.Tools.AskUser do
  @moduledoc """
  Human-in-the-loop tool. When the LLM calls this, the agent pauses
  and waits for the user to respond. The response is delivered as a
  tool_result when the user sends a message.

  This tool's handler is never actually called — the agent process
  intercepts it and handles the interrupt flow directly.
  """

  use Norns.Tools.Behaviour

  @impl true
  def name, do: "ask_user"

  @impl true
  def description do
    "Ask the user a question and wait for their response. Use this when you need clarification, " <>
      "confirmation, or additional information before proceeding. The agent will pause until " <>
      "the user responds."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "description" => "The question to ask the user"
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  def execute(_input) do
    # This should never be called directly — the agent process intercepts ask_user
    # tool calls before they reach the executor.
    {:error, "ask_user must be handled by the agent process, not executed directly"}
  end
end
