defmodule Norns.Runtime.Events.LlmResponse do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("llm_response", attrs)
end
