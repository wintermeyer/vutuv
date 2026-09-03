defmodule VutuvWeb.FeedArrivalReaderPassesTest do
  @moduledoc """
  A post that arrives while a page is open must be put through the reader's own
  two passes before anything shows or quotes it: their search-and-replace rules
  (`Vutuv.PostRewrites`), then their content filters.

  `Vutuv.Posts.newest_source_entry/3` answers with the post as it was written,
  and both of its callers once forgot a pass — the feed's pill streamed a
  fediverse arrival raw, and the browser tab's teaser quoted un-rewritten text.
  Each has one place that discharges the obligation now (`for_reader/2` in the
  feed, `PostTeaser.quote_for/4` for anything that quotes), so this guards the
  caller that comes third: a source read with no discharge beside it is the
  shape of both bugs.

  A source grep, deliberately: what it pins is that the obligation was *seen*,
  which no runtime assertion can ask of a caller nobody has written yet. The
  behaviour itself is covered by `feed_post_rewrites_test.exs`,
  `feed_remote_posts_test.exs` and `browser_tab_teaser_test.exs`.
  """
  use ExUnit.Case, async: true

  @source "newest_source_entry("
  @discharges ["for_reader(", "PostTeaser.quote_for("]

  test "every module reading an arrival discharges the reader's passes beside it" do
    readers = Enum.filter(lib_files(), &(File.read!(&1) =~ @source))

    # The context function that defines it is not a caller.
    readers = readers -- ["lib/vutuv/posts.ex"]

    offenders =
      Enum.reject(readers, fn path ->
        contents = File.read!(path)
        Enum.any?(@discharges, &(contents =~ &1))
      end)

    assert readers != [], "nothing calls #{@source} any more — retire this test"

    assert offenders == [],
           "#{@source} answers with the post as it was written. Put the entry " <>
             "through the reader's rewrite rules and content filters before you " <>
             "show or quote it (#{Enum.join(@discharges, " / ")}). " <>
             "Offending files: #{Enum.join(offenders, ", ")}"
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")
end
