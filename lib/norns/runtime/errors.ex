defmodule Norns.Runtime.Errors do
  @moduledoc false

  defmodule Error do
    @moduledoc false
    defexception [:class, :code, :message, details: %{}]
  end

  def classify(%Error{} = error), do: error

  def classify({429, message}) do
    %Error{class: :external_dependency, code: :rate_limited, message: "Rate limited: #{inspect(message)}", details: %{reason: inspect(message)}}
  end

  def classify({status, message}) when is_integer(status) and status >= 500 do
    %Error{class: :external_dependency, code: :upstream_unavailable, message: "Upstream failure: #{inspect(message)}", details: %{status: status, reason: inspect(message)}}
  end

  def classify({:validation, code, message}) do
    %Error{class: :validation, code: code, message: message, details: %{}}
  end

  def classify({:policy, code, message}) do
    %Error{class: :policy, code: code, message: message, details: %{}}
  end

  def classify({:internal, message}) when is_binary(message) do
    %Error{class: :internal, code: :runtime_failure, message: message, details: %{}}
  end

  def classify({:timeout, reason}) do
    %Error{class: :transient, code: :timeout, message: "Timeout: #{inspect(reason)}", details: %{reason: inspect(reason)}}
  end

  def classify(:timeout) do
    %Error{class: :transient, code: :timeout, message: "Timeout", details: %{}}
  end

  def classify(%Ecto.Changeset{} = changeset) do
    %Error{class: :validation, code: :invalid_payload, message: "Validation failed", details: %{errors: inspect(changeset.errors)}}
  end

  def classify(reason) do
    %Error{class: :internal, code: :unexpected_failure, message: Exception.format_banner(:error, reason), details: %{reason: inspect(reason)}}
  end

  def to_metadata(%Error{} = error) do
    %{
      "error_class" => Atom.to_string(error.class),
      "error_code" => Atom.to_string(error.code),
      "error" => error.message,
      "details" => error.details
    }
  end
end
