defmodule Vutuv.PostBodyChokepointTest do
  @moduledoc """
  **The invariant: a post's body leaves the database toward a surface a machine
  can read only through a query that asked `machines_allowed?`** (issue #2107).

  Three review rounds found three more leaks, each one complete when it was
  measured and each one missing the next: round 1 the archive, the tag pages and
  the calendar; round 2 the conversation, the reply, the repost and the profile
  document; round 3 the profile HTML's who-to-follow rail and its pinned card.
  The sites cannot be enumerated by hand — there is no list, only a property —
  and the last pair proved it twice over: `recent_posts_by_authors/3` selects
  `body:` into **bare maps**, which no struct-taking helper could ever have
  reached, and `pinned_post/2` fetches by id rather than through a timeline, so
  no listing gate applied.

  So the property is enforced here instead, the way `Vutuv.SchemaUuidChokepointTest`
  and `Vutuv.Notifications.MailerChokepointTest` enforce theirs: read the source,
  collect what breaks the rule, and fail the build with the offenders named.

  **An exception is explicit and carries its reason.** A surface that shows the
  text to a **person** on purpose is listed in `@deliberate` below with why; the
  silent absence of a check is what this test exists to stop.
  """
  use ExUnit.Case, async: true

  # The whole context layer, not just `posts.ex`: a query carrying a body could
  # be written in any of these, and the census that drove this test found the
  # one outside `posts.ex` (`Vutuv.Mentions`) only by looking at all of them.
  @context "lib/vutuv/*.ex"
  @agent_docs "lib/vutuv_web/agent_docs"

  # A body-selecting query that is **not** a leak, each with its reason. Two
  # shapes, and they are different reasons rather than one loose "allowed":
  # a body nothing renders, and a body that is not a post's at all.
  @exempt_queries %{
    "mentions.ex" =>
      "counts how many posts name a handle (Enum.count over the rows); the body " <>
        "is never returned, never rendered and never reaches a template",
    "chat.ex" =>
      "a private message between two members, not a post: `Vutuv.Chat.Message` " <>
        "carries no `noindex_noai?`, and no machine reads a direct message"
  }

  # The two spellings of the gate. `scope_machines_for/2` is the one to reach
  # for (it keeps a member's own posts for them); `scope_machines_allowed/1` is
  # its anonymous case, for a query with no viewer to make an exception for.
  @gates ["scope_machines_for(", "scope_machines_allowed("]

  # Documents whose **subject** post keeps its body, deliberately.
  #
  # A permalink document is one post's own document, and it carries that post's
  # answer in its own headers: a withheld post's `.md`/`.txt`/`.json`/`.xml`
  # sibling is served with `noindex, noai, noimageai` and an all-no
  # `Content-Signal`, which is exactly the shape a member-level opt-out already
  # has. What the switch is about is a **list** — an archive, a tag page, a
  # profile, a conversation — which carries one all-yes signal for many rows and
  # cannot signal per row. So the subject stays and the neighbours are redacted.
  @deliberate %{
    {"post_doc.ex", 95} => "the permalink doc's own subject post; its headers carry the answer",
    {"post_doc.ex", 98} => "same document, the subject's body",
    {"post_doc.ex", 103} => "link extraction from the subject's body, not text output",
    {"post_doc.ex", 217} => "the organization permalink doc's own subject post",
    {"post_doc.ex", 220} => "same document, the subject's body",
    {"organization_doc.ex", 121} =>
      "a page's post listing, already gated in the query by scope_machines_for_page/3"
  }

  test "every query that selects a post body pipes through the machines gate" do
    offenders =
      body_selecting_functions()
      |> Enum.reject(fn {file, _name, body} ->
        Map.has_key?(@exempt_queries, file) or Enum.any?(@gates, &String.contains?(body, &1))
      end)
      |> Enum.map(fn {file, name, _body} -> "#{file} #{name}/?" end)

    assert offenders == [],
           """
           These functions under lib/vutuv/ select a post's `body` and do not pipe
           the query through `Vutuv.Posts.scope_machines_for/2` (or its anonymous
           case `scope_machines_allowed/1`):

             #{Enum.join(offenders, "\n  ")}

           A post whose author keeps search engines and AI out (issue #2107) must not
           reach a page a crawler reads. `scope_visible/2` answers a different
           question — may this VIEWER see it — and a withheld post is public, it is
           simply not for machines. Pipe through the gate, or, if the surface shows
           the text to a person on purpose, say so where the query is built.
           """
  end

  # Calibration, the line `Vutuv.SchemaUuidChokepointTest` calls the most
  # important one it has: if the scanner stops finding the queries it is meant
  # to judge, the assertion above passes while testing nothing at all. The
  # census behind this test counted **three** such functions across `lib/vutuv/`
  # — `Posts.fetch_recent_posts/4`, `Mentions.count_post_mentions/1` and one in
  # `Chat` — so the floor is the whole population, not a guess.
  test "the scanner still finds the body-selecting queries it judges" do
    found = body_selecting_functions()

    assert length(found) >= 3,
           "expected at least the three known body-selecting queries " <>
             "(Posts.fetch_recent_posts/4, Mentions.count_post_mentions/1, Chat), found " <>
             "#{length(found)}: #{inspect(Enum.map(found, fn {f, n, _} -> "#{f} #{n}" end))}. " <>
             "The scanner has stopped measuring, so the guard above is vacuous."
  end

  test "no agent document quotes a local post's body without the machine gate" do
    offenders =
      Path.wildcard(Path.join(@agent_docs, "*.ex"))
      |> Enum.flat_map(&body_reads/1)
      |> Enum.reject(fn {file, line, _text} -> Map.has_key?(@deliberate, {file, line}) end)

    assert offenders == [],
           """
           These lines under #{@agent_docs}/ read a local post's body or teaser
           without going through `VutuvWeb.PostTeaser.machine_line/2` or
           `machine_body/2`:

             #{Enum.map_join(offenders, "\n  ", fn {f, l, t} -> "#{f}:#{l}  #{t}" end)}

           An agent document IS the machine surface. Either route it through the
           machine-audience half of `VutuvWeb.PostTeaser`, or add the line to
           `@deliberate` in this file **with the reason it may show the words** —
           a silent missing check is what this guard exists to catch.

           Note the line numbers in `@deliberate` move when the file does; a
           failure naming a line that looks right is usually that, and the fix is
           to re-read the line rather than to widen the rule.
           """
  end

  defp body_selecting_functions do
    @context
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      file = Path.basename(path)

      path
      |> functions_of()
      |> Enum.filter(fn {_name, body} -> selects_post_body?(body) end)
      |> Enum.map(fn {name, body} -> {file, name, body} end)
    end)
  end

  # A function is everything from one top-level `def`/`defp` to the next.
  defp functions_of(path) do
    path
    |> File.read!()
    |> String.split(~r/\n(?=  defp? [a-z_])/)
    |> Enum.map(fn chunk ->
      name =
        case Regex.run(~r/\A\s*defp? ([a-z_][a-zA-Z0-9_?!]*)/, chunk) do
          [_, name] -> name
          nil -> "(module body)"
        end

      {name, chunk}
    end)
  end

  # An Ecto select carrying a post body: `body: <binding>.body` inside a
  # `select`. Deliberately narrow — it is the shape that has actually leaked
  # twice, and a wide regex over `.body` would match every struct read in the
  # module and drown the signal.
  defp selects_post_body?(chunk) do
    String.contains?(chunk, "select") and
      (Regex.match?(~r/\n\s+body: [a-z]+\.body,?\n/, chunk) or
         Regex.match?(~r/select: [a-z]+\.body\b/, chunk))
  end

  # A local post's words leaving an agent document. Remote records are out of
  # scope by construction: a `%RemotePost{}`, a `%Note{}` and an
  # `%ExternalPost{}` carry no `noindex_noai?` column, their authors never gave
  # this installation an answer, and their bodies are somebody else's server's
  # to publish.
  @remote ~w(remote note subject external reference point)
  defp body_reads(path) do
    file = Path.basename(path)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} ->
      trimmed = String.trim(line)

      not String.starts_with?(trimmed, "#") and
        (Regex.match?(~r/PostTeaser\.(plain_)?line\(/, trimmed) or
           Regex.match?(~r/[a-z_]+\.body\b/, trimmed)) and
        not Enum.any?(@remote, &Regex.match?(~r/\b#{&1}(\.|\))/, trimmed))
    end)
    |> Enum.map(fn {line, n} -> {file, n, String.trim(line)} end)
  end
end
