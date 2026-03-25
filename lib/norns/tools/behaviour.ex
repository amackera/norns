defmodule Norns.Tools.Behaviour do
  @moduledoc """
  Behaviour for tool modules. Provides `use Norns.Tools.Behaviour` macro
  that auto-generates a `__tool__/0` function returning a `%Tool{}` struct.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback execute(input :: map()) :: {:ok, String.t()} | {:error, String.t()}
  @callback side_effect?() :: boolean()

  defmacro __using__(_opts) do
    quote do
      @behaviour Norns.Tools.Behaviour

      def __tool__ do
        %Norns.Tools.Tool{
          name: name(),
          description: description(),
          input_schema: input_schema(),
          handler: &execute/1,
          side_effect?: side_effect?()
        }
      end

      def to_api_format do
        Norns.Tools.Tool.to_api_format(__tool__())
      end

      def side_effect?, do: false
      defoverridable side_effect?: 0
    end
  end
end
