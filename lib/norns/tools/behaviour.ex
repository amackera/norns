defmodule Norns.Tools.Behaviour do
  @moduledoc """
  Behaviour for tool modules. Provides `use Norns.Tools.Behaviour` macro
  that auto-generates a `__tool__/0` function returning a `%Tool{}` struct.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback execute(input :: map()) :: {:ok, String.t()} | {:error, String.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Norns.Tools.Behaviour

      def __tool__ do
        %Norns.Tools.Tool{
          name: name(),
          description: description(),
          input_schema: input_schema(),
          handler: &execute/1
        }
      end

      def to_api_format do
        Norns.Tools.Tool.to_api_format(__tool__())
      end
    end
  end
end
