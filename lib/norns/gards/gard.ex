defmodule Norns.Gards.Gard do
  @moduledoc """
  A gard is a bounded execution context — a filesystem, a container, a VM —
  where exactly one worker operates. Norns tracks gards and routes tool
  dispatch to them; it never creates or manages the underlying
  infrastructure (that's the provisioner's job — see `docs/gards.md`).

  Statuses: `pending` (created, no worker yet) → `ready` (worker claimed) →
  `disconnected` (worker gone, reconnect allowed) → `destroyed` (terminal;
  soft-delete only, the row stays for referential integrity with runs).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending ready disconnected destroyed)

  schema "gards" do
    field :name, :string
    field :status, :string, default: "pending"
    field :template, :string
    field :claim_token, :string
    field :metadata, :map, default: %{}

    belongs_to :tenant, Norns.Tenants.Tenant
    has_many :ports, Norns.Gards.GardPort

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(gard, attrs) do
    gard
    |> cast(attrs, [:tenant_id, :name, :template, :metadata])
    |> validate_required([:tenant_id])
    |> put_claim_token()
  end

  def update_changeset(gard, attrs) do
    cast(gard, attrs, [:name, :template, :metadata])
  end

  # Claim tokens are always generated server-side — never user-supplied.
  defp put_claim_token(changeset) do
    case get_field(changeset, :claim_token) do
      nil ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        put_change(changeset, :claim_token, token)

      _ ->
        changeset
    end
  end
end
