defmodule Norns.Runtime.Events.ToolCall do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("tool_call", attrs)
end
