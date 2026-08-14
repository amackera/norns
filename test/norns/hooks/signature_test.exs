defmodule Norns.Hooks.SignatureTest do
  use ExUnit.Case, async: true

  alias Norns.Hooks.Signature

  @secret "whsec_test_secret"
  @body ~s({"event":"push"})

  defp hmac(data), do: :hmac |> :crypto.mac(:sha256, @secret, data) |> Base.encode16(case: :lower)

  defp hook(type), do: %{signature_type: type, signing_secret: @secret}

  describe "none" do
    test "always passes" do
      assert Signature.verify(hook("none"), @body, []) == :ok
    end
  end

  describe "github" do
    test "accepts a valid X-Hub-Signature-256" do
      headers = [{"x-hub-signature-256", "sha256=" <> hmac(@body)}]
      assert Signature.verify(hook("github"), @body, headers) == :ok
    end

    test "rejects a tampered body" do
      headers = [{"x-hub-signature-256", "sha256=" <> hmac(@body)}]
      assert Signature.verify(hook("github"), @body <> "x", headers) == {:error, "invalid_signature"}
    end

    test "rejects a missing header" do
      assert Signature.verify(hook("github"), @body, []) == {:error, "missing_signature"}
    end
  end

  describe "stripe" do
    test "accepts a valid Stripe-Signature" do
      timestamp = System.os_time(:second)
      headers = [{"stripe-signature", "t=#{timestamp},v1=#{hmac("#{timestamp}.#{@body}")}"}]
      assert Signature.verify(hook("stripe"), @body, headers) == :ok
    end

    test "rejects a stale timestamp" do
      timestamp = System.os_time(:second) - 600
      headers = [{"stripe-signature", "t=#{timestamp},v1=#{hmac("#{timestamp}.#{@body}")}"}]
      assert Signature.verify(hook("stripe"), @body, headers) == {:error, "stale_timestamp"}
    end

    test "rejects a wrong signature" do
      timestamp = System.os_time(:second)
      headers = [{"stripe-signature", "t=#{timestamp},v1=#{hmac("wrong")}"}]
      assert Signature.verify(hook("stripe"), @body, headers) == {:error, "invalid_signature"}
    end

    test "rejects a malformed header" do
      assert Signature.verify(hook("stripe"), @body, [{"stripe-signature", "garbage"}]) ==
               {:error, "missing_signature"}
    end
  end

  describe "slack" do
    test "accepts a valid v0 signature" do
      timestamp = to_string(System.os_time(:second))

      headers = [
        {"x-slack-signature", "v0=" <> hmac("v0:#{timestamp}:#{@body}")},
        {"x-slack-request-timestamp", timestamp}
      ]

      assert Signature.verify(hook("slack"), @body, headers) == :ok
    end

    test "rejects a replayed timestamp" do
      timestamp = to_string(System.os_time(:second) - 600)

      headers = [
        {"x-slack-signature", "v0=" <> hmac("v0:#{timestamp}:#{@body}")},
        {"x-slack-request-timestamp", timestamp}
      ]

      assert Signature.verify(hook("slack"), @body, headers) == {:error, "stale_timestamp"}
    end

    test "rejects a missing timestamp header" do
      headers = [{"x-slack-signature", "v0=" <> hmac("anything")}]
      assert Signature.verify(hook("slack"), @body, headers) == {:error, "missing_signature"}
    end
  end
end
