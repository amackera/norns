defmodule Norns.Runtime.Events.CheckpointSaved do
  @moduledoc false

  alias Norns.Runtime.Events

  def new(attrs), do: Events.build("checkpoint_saved", attrs)
end
