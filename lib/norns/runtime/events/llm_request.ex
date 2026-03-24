defmodule Norns.Runtime.Events.LlmRequest do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("llm_request", attrs)
end
