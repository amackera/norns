defmodule Norns.Tools.WebSearch do
  @moduledoc "Demo web search tool. Returns a stub result for now."

  use Norns.Tools.Behaviour

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web for information. Returns a summary of search results."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The search query"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    {:ok, "Search results for '#{query}': This is a stub result. No actual web search was performed."}
  end

  def execute(_), do: {:error, "Missing required parameter: query"}

  # Backward compat alias
  def tool, do: __tool__()
end
