defmodule Norns.Runtime.Events.ToolDuplicate do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("tool_duplicate", attrs)
end
