defmodule Norns.Hooks.Signature do
  @moduledoc """
  Provider signature verification for inbound webhooks.

  Verification runs against the **raw request body** (cached before JSON
  parsing — see `NornsWeb.CacheBodyReader`), because every provider signs
  bytes on the wire, not parsed params. All comparisons are constant-time.

  Supported schemes:

    * `"none"` — token-in-URL only
    * `"github"` — `X-Hub-Signature-256: sha256=<hmac>` over the body
    * `"stripe"` — `Stripe-Signature: t=<ts>,v1=<hmac>` over `"{t}.{body}"`
    * `"slack"` — `X-Slack-Signature: v0=<hmac>` over
      `"v0:{X-Slack-Request-Timestamp}:{body}"`

  Stripe and Slack signatures include a timestamp; deliveries older than
  #{5} minutes are rejected to bound replay.
  """

  @tolerance_seconds 300

  @doc """
  Verify a delivery. `headers` is a `{name, value}` list with lowercase
  names (as `conn.req_headers` provides). Returns `:ok` or `{:error, code}`
  with a stable code: `"missing_signature"`, `"invalid_signature"`, or
  `"stale_timestamp"`.
  """
  def verify(%{signature_type: "none"}, _raw_body, _headers), do: :ok

  def verify(%{signature_type: "github", signing_secret: secret}, raw_body, headers) do
    with {:ok, header} <- fetch_header(headers, "x-hub-signature-256") do
      expected = "sha256=" <> hmac_hex(secret, raw_body)
      compare(header, expected)
    end
  end

  def verify(%{signature_type: "stripe", signing_secret: secret}, raw_body, headers) do
    with {:ok, header} <- fetch_header(headers, "stripe-signature"),
         %{"t" => timestamp, "v1" => signature} <- parse_kv(header, ","),
         :ok <- check_timestamp(timestamp) do
      expected = hmac_hex(secret, "#{timestamp}.#{raw_body}")
      compare(signature, expected)
    else
      {:error, _} = error -> error
      _ -> {:error, "missing_signature"}
    end
  end

  def verify(%{signature_type: "slack", signing_secret: secret}, raw_body, headers) do
    with {:ok, signature} <- fetch_header(headers, "x-slack-signature"),
         {:ok, timestamp} <- fetch_header(headers, "x-slack-request-timestamp"),
         :ok <- check_timestamp(timestamp) do
      expected = "v0=" <> hmac_hex(secret, "v0:#{timestamp}:#{raw_body}")
      compare(signature, expected)
    end
  end

  defp hmac_hex(secret, data) do
    :hmac
    |> :crypto.mac(:sha256, secret, data)
    |> Base.encode16(case: :lower)
  end

  defp compare(provided, expected) do
    if Plug.Crypto.secure_compare(provided, expected) do
      :ok
    else
      {:error, "invalid_signature"}
    end
  end

  defp fetch_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing_signature"}
    end
  end

  # "t=123,v1=abc" → %{"t" => "123", "v1" => "abc"}
  defp parse_kv(header, separator) do
    header
    |> String.split(separator)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), value)
        _ -> acc
      end
    end)
  end

  defp check_timestamp(timestamp) do
    with {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.os_time(:second) - seconds) <= @tolerance_seconds do
      :ok
    else
      _ -> {:error, "stale_timestamp"}
    end
  end
end
