defmodule Vutuv.SitemapDevDocsTest do
  @moduledoc """
  The sitemap must list every public developer-doc page. DevDocController's
  registry is the single source of truth for which pages exist and are served
  under /developers/:page; this test fails the build if one is added there but
  not mirrored into Vutuv.Sitemap (issue: cookbook + data-model were missing).
  """
  use ExUnit.Case, async: true

  test "every served dev-doc page appears in the sitemap" do
    static = Vutuv.Sitemap.static_paths()

    for slug <- VutuvWeb.DevDocController.doc_pages() do
      assert "/developers/#{slug}" in static,
             "sitemap is missing /developers/#{slug} — add it to Vutuv.Sitemap @dev_doc_pages"
    end
  end

  test "the sitemap does not list a dev-doc page that 404s" do
    served = MapSet.new(VutuvWeb.DevDocController.doc_pages(), &"/developers/#{&1}")

    sitemap_dev_pages =
      Vutuv.Sitemap.static_paths()
      |> Enum.filter(&String.starts_with?(&1, "/developers/"))

    for path <- sitemap_dev_pages do
      assert path in served, "sitemap lists #{path}, which DevDocController does not serve"
    end
  end
end
