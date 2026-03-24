defmodule Norns.Runtime.Events.ToolResult do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("tool_result", attrs)
end
