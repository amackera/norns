defmodule Norns.LLM do
  @moduledoc """
  LLM dispatcher, used as a test seam for simulating a worker's provider call
  (see `Norns.TestWorker`). The real runtime never calls a provider from the
  orchestrator — connected workers translate the neutral format and call their
  own provider. There is intentionally no built-in provider adapter here.

  Configure a backend module (e.g. `Norns.LLM.Fake` in tests) via:
    config :norns, Norns.LLM, module: Norns.LLM.Fake
  """

  @doc "Multi-turn chat with optional tool definitions."
  def chat(api_key, model, system_prompt, messages, opts \\ []) do
    impl().chat(api_key, model, system_prompt, messages, opts)
  end

  @doc "Backward-compatible single-turn completion."
  def complete(api_key, model, system_prompt, user_message, opts \\ []) do
    messages = [%{role: "user", content: user_message}]

    case chat(api_key, model, system_prompt, messages, opts) do
      {:ok, %{content: content}} ->
        text =
          content
          |> Enum.find_value(fn
            %{"type" => "text", "text" => t} -> t
            _ -> nil
          end)

        if text, do: {:ok, text}, else: {:error, :no_text_in_response}

      error ->
        error
    end
  end

  defp impl do
    case Application.get_env(:norns, __MODULE__, [])[:module] do
      nil ->
        raise "Norns.LLM has no backend configured. This dispatcher is a test " <>
                "seam; the real runtime dispatches to connected workers, which " <>
                "translate and call their own provider."

      module ->
        module
    end
  end
end
