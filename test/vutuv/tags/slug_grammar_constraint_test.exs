defmodule Vutuv.Tags.SlugGrammarConstraintTest do
  @moduledoc """
  What keeps tag slugs inside the actor grammar once they are there (issue
  #1332, the last piece): the database constraint and the changeset that says
  the same thing before it.

  Both halves matter. The constraint is the guarantee #1330 mints actors on;
  the validation is what turns an admin's hand-typed slug into a field error
  rather than a 500.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Tags.Tag

  defp changeset(attrs), do: Tag.edit_changeset(%Tag{}, attrs)

  test "a live slug may hold only lowercase letters, digits and underscores" do
    assert %{valid?: true} = changeset(%{"name" => "Elixir", "slug" => "elixir_lang"})

    for bad <- ["elixir-lang", "Elixir", "elixir.lang", "elixir lang", "c++"] do
      cs = changeset(%{"name" => "Elixir", "slug" => bad})
      refute cs.valid?, "#{bad} passed"
      assert "may contain only lowercase letters, digits and underscores" in errors_on(cs).slug
    end
  end

  test "an alias keeps the retired spelling it exists to preserve" do
    n = System.unique_integer([:positive])
    topic = insert(:tag, name: "Topic #{n}", slug: "topic_#{n}")

    # The row that makes `/tags/<old>` answer 301 has to be allowed to hold
    # exactly the shape the constraint forbids everywhere else. Written the way
    # the retag migration writes it, which is what actually files these.
    retired =
      Repo.insert!(%Tag{
        name: "topic-#{n}",
        slug: "topic-#{n}",
        merged_into_id: topic.id,
        alias_kind: "former"
      })

    assert retired.slug == "topic-#{n}"
  end

  test "the database refuses a live row the validation would have caught" do
    n = System.unique_integer([:positive])

    # Straight past the changeset, the way a migration or a raw statement would.
    assert_raise Postgrex.Error, ~r/tags_slug_actor_grammar/, fn ->
      Repo.query!(
        "insert into tags (id, name, slug, inserted_at, updated_at) values ($1, $2, $3, now(), now())",
        [
          Ecto.UUID.dump!(Vutuv.UUIDv7.generate()),
          "Bad #{n}",
          "bad-#{n}"
        ]
      )
    end
  end
end
