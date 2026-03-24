defmodule Norns.Runtime.Events.RunCompleted do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("run_completed", attrs)
end
