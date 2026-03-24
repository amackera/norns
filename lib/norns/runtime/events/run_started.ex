defmodule Norns.Runtime.Events.RunStarted do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs \\ %{}), do: Events.build("run_started", attrs)
end
