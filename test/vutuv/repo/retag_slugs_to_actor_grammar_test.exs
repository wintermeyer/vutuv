defmodule Vutuv.Repo.RetagSlugsToActorGrammarTest do
  @moduledoc """
  Covers the one-time migration `retag_slugs_to_actor_grammar` (issues #1337 and
  #1332, want 2), which brings every live tag slug into `^[a-z0-9_]+$` — the
  grammar #1330 needs, because a tag slug becomes that tag's fediverse actor
  name.

  The run that matters is against a copy of the real catalog (see CLAUDE.md); on
  8,036 tags it reported 262 live slugs to rename: 217 free, 15 swapped with
  their own alias, 30 keeping their existing collision suffix. This file builds
  each of those three shapes by hand, so the rules cannot drift and so a fresh
  installation's empty catalog is not the only thing CI ever sees.

  `async: false`: the module is loaded from `priv/repo/migrations` with
  `Code.require_file/1`, which is global.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Tags.Tag

  @migration Vutuv.Repo.Migrations.RetagSlugsToActorGrammar
  @grammar ~r/^[a-z0-9_]+$/

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [file] = Path.wildcard("priv/repo/migrations/*_retag_slugs_to_actor_grammar.exs")
      Code.require_file(file)
    end

    :ok
  end

  defp tag(name, slug, attrs \\ []), do: insert(:tag, [name: name, slug: slug] ++ attrs)

  defp reload(%Tag{id: id}), do: Repo.get!(Tag, id)

  defp alias_of(%Tag{id: id}) do
    Repo.one(from(t in Tag, where: t.merged_into_id == ^id, order_by: [desc: t.id], limit: 1))
  end

  test "a hyphen slug is renamed and its old spelling keeps resolving" do
    n = System.unique_integer([:positive])
    topic = tag("Machine Learning #{n}", "machine-learning-#{n}")

    @migration.up()

    assert reload(topic).slug == "machine_learning_#{n}"

    # The retired spelling stays in the table as a `former` alias, which is what
    # makes `/tags/<old>` answer 301 instead of 404.
    assert %Tag{} = retired = Repo.get_by(Tag, slug: "machine-learning-#{n}")
    assert retired.merged_into_id == topic.id
    assert retired.alias_kind == "former"
  end

  test "a collision suffix loses its dot rather than its identity" do
    n = System.unique_integer([:positive])
    # The shape 165 rows carry: a name whose slug was already taken, so the
    # slugifier appended `.<sha>`. The wanted slug is taken here too, so the row
    # keeps the suffix it has — one character changed, the URL still readable.
    tag("Grafana #{n}", "grafana_#{n}")
    dupe = tag("Grafana #{n}", "grafana_#{n}.a23c7928")

    @migration.up()

    # Two live topics under one name is a merge for a human to decide at
    # /admin/tag_merges, never for a migration, so the second one keeps a page
    # of its own — with the suffix it already had.
    assert reload(dupe).slug == "grafana_#{n}_a23c7928"
  end

  test "a tag whose own alias holds the wanted slug swaps with it, adding no row" do
    n = System.unique_integer([:positive])
    topic = tag("Open-Source Software #{n}", "open-source-software-#{n}")

    absorbed =
      tag("open source software #{n}", "open_source_software_#{n}", merged_into_id: topic.id)

    before = Repo.aggregate(Tag, :count)

    @migration.up()

    # Both slugs already resolved to this one topic, so they simply exchange
    # them: no third row, and nothing changes meaning.
    assert reload(topic).slug == "open_source_software_#{n}"
    assert reload(absorbed).slug == "open-source-software-#{n}"
    assert Repo.aggregate(Tag, :count) == before
  end

  test "an already conforming slug is left alone" do
    n = System.unique_integer([:positive])
    untouched = tag("Elixir #{n}", "elixir_#{n}")

    @migration.up()

    assert reload(untouched).slug == "elixir_#{n}"
    refute alias_of(untouched)
  end

  test "every live slug conforms afterwards, and the rollback puts them all back" do
    n = System.unique_integer([:positive])

    rows = [
      tag("Ruby on Rails #{n}", "ruby-on-rails-#{n}"),
      tag("Prozessanalyse #{n}", "prozessanalyse#{n}.a635dc6a"),
      tag("Node.js #{n}", "node_js_#{n}")
    ]

    slugs_before = Enum.map(rows, & &1.slug)
    count_before = Repo.aggregate(Tag, :count)

    @migration.up()

    live = Repo.all(from(t in Tag, where: is_nil(t.merged_into_id), select: t.slug))
    assert Enum.all?(live, &Regex.match?(@grammar, &1)), "a live slug is not an actor name"

    @migration.down()

    assert Enum.map(rows, &reload(&1).slug) == slugs_before
    assert Repo.aggregate(Tag, :count) == count_before
  end
end
