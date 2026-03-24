defmodule Norns.Runtime.Event do
  @moduledoc false

  @enforce_keys [:event_type, :payload]
  defstruct [:event_type, :source, :metadata, :payload]

  @type t :: %__MODULE__{
          event_type: String.t(),
          source: String.t() | nil,
          metadata: map() | nil,
          payload: map()
        }
end
