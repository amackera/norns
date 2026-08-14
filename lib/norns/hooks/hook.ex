defmodule Norns.Hooks.Hook do
  @moduledoc """
  An inbound webhook: `POST /api/v1/hooks/:token` starts a run on the mapped
  agent. Pure ingress — this is the messages endpoint with per-hook token
  auth, so services that speak HTTP (Twilio, Mailgun, GitHub, Stripe) become
  configuration instead of connector code.

  The token in the URL is the credential; it is server-generated and unique.
  Optional extras:

    * `message_path` — dot-path into the JSON payload used as the run's
      message (e.g. `"Body"` for Twilio SMS). Unset, the whole payload is
      passed as pretty-printed JSON.
    * `conversation_key_path` — dot-path whose value keys the conversation
      (e.g. `"From"`, so each phone number keeps its own history). Unset,
      every delivery starts a fresh conversation.
    * `signature_type` + `signing_secret` — provider signature verification
      (`github`, `stripe`, `slack`, or `none`). See `Norns.Hooks.Signature`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @signature_types ~w(none github stripe slack)

  schema "hooks" do
    field :name, :string
    field :token, :string
    field :message_path, :string
    field :conversation_key_path, :string
    field :signature_type, :string, default: "none"
    field :signing_secret, :string
    field :enabled, :boolean, default: true

    belongs_to :tenant, Norns.Tenants.Tenant
    belongs_to :agent, Norns.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def signature_types, do: @signature_types

  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [
      :tenant_id,
      :agent_id,
      :name,
      :message_path,
      :conversation_key_path,
      :signature_type,
      :signing_secret,
      :enabled
    ])
    |> validate_required([:tenant_id, :agent_id, :name])
    |> validate_inclusion(:signature_type, @signature_types)
    |> validate_secret_present()
    |> put_token()
    |> unique_constraint([:tenant_id, :name])
    |> unique_constraint(:token)
    |> foreign_key_constraint(:agent_id)
  end

  defp validate_secret_present(changeset) do
    type = get_field(changeset, :signature_type)
    secret = get_field(changeset, :signing_secret)

    if type != "none" and (is_nil(secret) or secret == "") do
      add_error(changeset, :signing_secret, "is required when signature_type is #{type}")
    else
      changeset
    end
  end

  # Tokens are always generated server-side — never user-supplied.
  defp put_token(changeset) do
    case get_field(changeset, :token) do
      nil ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        put_change(changeset, :token, token)

      _ ->
        changeset
    end
  end
end
