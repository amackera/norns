defmodule Norns.Gards.GardPort do
  @moduledoc """
  A port exposed by a service running inside a gard, with the externally
  reachable URL (localhost for local gards, a tunnel URL for remote ones).
  Norns stores and displays these; it never proxies traffic.

  Ports belong to the gard, not the worker — they survive worker
  disconnect/reconnect and are removed only when the gard is destroyed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # URL schemes are restricted to prevent XSS via links rendered in the
  # dashboard (e.g. javascript: URLs).
  @allowed_schemes ~w(http https tcp)

  schema "gard_ports" do
    field :internal_port, :integer
    field :url, :string
    field :name, :string
    field :protocol, :string, default: "http"

    belongs_to :gard, Norns.Gards.Gard

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(port, attrs) do
    port
    |> cast(attrs, [:gard_id, :internal_port, :url, :name, :protocol])
    |> validate_required([:gard_id, :internal_port])
    |> validate_number(:internal_port, greater_than: 0, less_than: 65_536)
    |> validate_inclusion(:protocol, @allowed_schemes)
    |> validate_url_scheme()
    |> foreign_key_constraint(:gard_id)
  end

  defp validate_url_scheme(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.parse(url).scheme do
        scheme when scheme in @allowed_schemes -> []
        _ -> [url: "scheme must be one of: #{Enum.join(@allowed_schemes, ", ")}"]
      end
    end)
  end
end
