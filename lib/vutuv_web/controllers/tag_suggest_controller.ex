defmodule VutuvWeb.TagSuggestController do
  @moduledoc """
  The JSON behind every tag field's suggestion list (`assets/js/tag_suggest.js`).

  Two questions, one address. `q` is the half-typed name: the answer is that
  name resolved to the topic it would be saved as (`typed`, always the list's
  first row, so Enter never picks something the member did not type) and the
  existing topics it starts (`results`). `names` is the pills a box already
  holds: the answer says which topic each one becomes and how many members
  carry it, for pills the box got without asking (a restored draft, a pasted
  line, a comma).

  Public, because the first tag field anybody meets is the sign-up form's. It
  says nothing a tag page does not already say: the names of topics and how
  many listed members carry them.
  """
  use VutuvWeb, :controller

  alias Vutuv.SearchText
  alias Vutuv.Tags
  alias Vutuv.Tags.MatchKey
  alias Vutuv.Tags.Tag

  # More names than any box holds (a profile takes 15), so a real box always
  # gets a whole answer, and a crafted request cannot make one lookup huge.
  @max_names 20

  def index(conn, %{"names" => names}) when is_binary(names) do
    counts =
      names
      |> String.split(",")
      |> Enum.map(&Tag.normalize_value/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(@max_names)
      |> Tags.resolve_typed_names()
      |> Enum.map(fn {typed, name, count} -> %{typed: typed, name: name, count: count} end)

    json(conn, %{counts: counts})
  end

  def index(conn, params) do
    query = params |> Map.get("q", "") |> to_string() |> SearchText.cap() |> Tag.normalize_value()
    typed = typed_row(query)

    typed_key = typed && MatchKey.normalize(typed.name)
    results = query |> Tags.suggest() |> Enum.reject(&(MatchKey.normalize(&1.name) == typed_key))

    json(conn, %{typed: typed, results: results})
  end

  defp typed_row(""), do: nil

  defp typed_row(query) do
    [{_typed, name, count}] = Tags.resolve_typed_names([query])
    %{name: name, count: count}
  end
end
