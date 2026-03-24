defmodule Norns.Runtime.Events.RunFailed do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("run_failed", attrs)
end
