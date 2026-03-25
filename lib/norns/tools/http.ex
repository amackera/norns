defmodule Norns.Tools.Http do
  @moduledoc "HTTP request tool. Makes GET/POST requests via Req."

  use Norns.Tools.Behaviour

  @max_body_length 1_500

  @impl true
  def name, do: "http_request"

  @impl true
  def description do
    "Make an HTTP request. Supports GET and POST methods. HTML responses are stripped to text content."
  end

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to request"},
        "method" => %{"type" => "string", "enum" => ["GET", "POST"], "description" => "HTTP method (default: GET)"},
        "body" => %{"type" => "string", "description" => "Request body for POST requests"},
        "headers" => %{"type" => "object", "description" => "Optional HTTP headers"}
      },
      "required" => ["url"]
    }
  end

  @impl true
  def execute(%{"url" => url} = input) do
    method = String.upcase(input["method"] || "GET")
    headers = input["headers"] |> parse_headers() |> maybe_put_idempotency_header(method)
    body = input["body"]

    result =
      case method do
        "GET" ->
          Req.get(url, headers: headers, receive_timeout: 30_000, retry: false)

        "POST" ->
          opts = [headers: headers, receive_timeout: 30_000, retry: false]
          opts = if body, do: Keyword.put(opts, :body, body), else: opts
          Req.post(url, opts)

        other ->
          {:error, "Unsupported method: #{other}"}
      end

    case result do
      {:ok, %Req.Response{status: status, body: body}} ->
        body_str = if is_binary(body), do: body, else: Jason.encode!(body)
        cleaned = clean_body(body_str)
        truncated = String.slice(cleaned, 0, @max_body_length)
        suffix = if String.length(cleaned) > @max_body_length, do: "\n...(truncated)", else: ""
        {:ok, "HTTP #{status}\n\n#{truncated}#{suffix}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: url"}

  defp clean_body(body) do
    if String.contains?(body, "<html") or String.contains?(body, "<!DOCTYPE") do
      strip_html(body)
    else
      body
    end
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
    |> String.replace(~r/<nav[^>]*>.*?<\/nav>/s, "")
    |> String.replace(~r/<header[^>]*>.*?<\/header>/s, "")
    |> String.replace(~r/<footer[^>]*>.*?<\/footer>/s, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-zA-Z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp parse_headers(nil), do: []
  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
  defp parse_headers(_), do: []

  defp maybe_put_idempotency_header(headers, "POST") do
    case Process.get(:norns_tool_context) do
      %{idempotency_key: key} when is_binary(key) -> [{"idempotency-key", key} | headers]
      _ -> headers
    end
  end

  defp maybe_put_idempotency_header(headers, _method), do: headers
end
