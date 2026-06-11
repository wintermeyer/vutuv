defmodule VutuvWeb.ApiV1.Problem do
  @moduledoc """
  RFC 9457 `application/problem+json` error responses — the one error shape
  every `/api/v1` endpoint speaks. Halts the conn.
  """

  import Plug.Conn

  def send_problem(conn, status, title, opts \\ []) do
    body =
      %{title: title, status: status}
      |> put_detail(Keyword.get(opts, :detail))
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    conn
    |> merge_resp_headers(Keyword.get(opts, :headers, []))
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  @doc """
  The API's uniform 404. Deliberately the same for "does not exist" and
  "exists but is hidden from you" — like the HTML pages, so the API cannot
  be used to probe for hidden accounts.
  """
  def not_found(conn, detail \\ "The resource does not exist or is not visible to you.") do
    send_problem(conn, 404, "Not found", detail: detail)
  end

  @doc """
  The 422 every write endpoint answers on changeset errors: per-field
  message lists under `errors`, the same texts the HTML forms show.
  """
  def validation_failed(conn, %Ecto.Changeset{} = changeset) do
    send_problem(conn, 422, "Validation failed",
      detail: "One or more fields are invalid.",
      extra: %{errors: changeset_errors(changeset)}
    )
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", stringify(value))
      end)
    end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp stringify(value), do: inspect(value)

  defp put_detail(body, nil), do: body
  defp put_detail(body, detail), do: Map.put(body, :detail, detail)
end
