defmodule Vutuv.Profiles.VerifiedLinksTest do
  @moduledoc """
  The matching rule behind the "this link is the author's own, proven site"
  mark on a post (issue #1246).

  A proof states a scope, and the mark is a trust signal: claiming more than
  was proved is worse than not marking at all. The shared-hosting case is the
  reason this module exists — a member who proves `example.com/~alice` by a
  rel=me back-link has said nothing about `example.com/~bob`.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.VerifiedLinks

  defp link(value, method) do
    %Url{
      value: value,
      verification_method: method,
      verified_at: ~N[2026-08-01 10:00:00]
    }
  end

  defp matches?(links, url), do: VerifiedLinks.match(url, links) != nil

  describe "a whole-host proof (dns / well_known)" do
    for method <- ~w(dns well_known) do
      test "#{method} marks any link on that host" do
        links = [link("https://example.com/", unquote(method))]

        assert matches?(links, "https://example.com/")
        assert matches?(links, "https://example.com/anything/deep")
        assert matches?(links, "https://example.com/~bob")
      end
    end

    test "the proof does not reach a different host" do
      links = [link("https://example.com/", "dns")]

      refute matches?(links, "https://example.org/")
      refute matches?(links, "https://notexample.com/")
      # A subdomain is a different host: nothing proved it.
      refute matches?(links, "https://blog.example.com/")
    end

    test "a host proof stored with a path still covers the host" do
      # The member may have entered https://example.com/home and proved the
      # DOMAIN by DNS — the proof is about the host either way.
      links = [link("https://example.com/home", "well_known")]

      assert matches?(links, "https://example.com/somewhere-else")
    end
  end

  describe "a rel=me proof at the host root" do
    test "is effectively a host claim" do
      for root <- ["https://example.com", "https://example.com/", "http://example.com/"] do
        links = [link(root, "rel_me")]

        assert matches?(links, "https://example.com/blog/2026/post"),
               "#{root} should read as a host claim"
      end
    end
  end

  describe "a rel=me proof on a deeper path" do
    setup do
      %{links: [link("https://example.com/~alice", "rel_me")]}
    end

    test "marks that exact page", %{links: links} do
      assert matches?(links, "https://example.com/~alice")
    end

    test "does not mark a neighbour on the same shared host", %{links: links} do
      refute matches?(links, "https://example.com/~bob")
    end

    test "does not mark a page below the proven one", %{links: links} do
      refute matches?(links, "https://example.com/~alice/foo")
    end

    test "does not mark the host root", %{links: links} do
      refute matches?(links, "https://example.com/")
    end
  end

  describe "normalisation" do
    test "www. is the same party on either side" do
      assert matches?([link("https://www.example.com/", "dns")], "https://example.com/x")
      assert matches?([link("https://example.com/", "dns")], "https://www.example.com/x")

      assert matches?(
               [link("https://www.example.com/~alice", "rel_me")],
               "https://example.com/~alice"
             )
    end

    test "http and https are the same site" do
      assert matches?([link("http://example.com/~alice", "rel_me")], "https://example.com/~alice")
      assert matches?([link("https://example.com/~alice", "rel_me")], "http://example.com/~alice")
    end

    test "a trailing slash does not change the page" do
      assert matches?(
               [link("https://example.com/~alice/", "rel_me")],
               "https://example.com/~alice"
             )

      assert matches?(
               [link("https://example.com/~alice", "rel_me")],
               "https://example.com/~alice/"
             )
    end

    test "query and fragment are ignored — the same page, shared with tracking" do
      links = [link("https://example.com/~alice", "rel_me")]

      assert matches?(links, "https://example.com/~alice?utm_source=newsletter")
      assert matches?(links, "https://example.com/~alice#intro")
      assert matches?(links, "https://example.com/~alice/?utm_source=x#top")
    end

    test "the host is compared case-insensitively" do
      assert matches?([link("https://Example.COM/", "dns")], "https://example.com/x")
    end

    test "the path keeps its case — a case-sensitive server serves two pages" do
      refute matches?(
               [link("https://example.com/~Alice", "rel_me")],
               "https://example.com/~alice"
             )
    end

    test "a non-http(s) or unparseable address matches nothing" do
      links = [link("https://example.com/", "dns")]

      refute matches?(links, "mailto:alice@example.com")
      refute matches?(links, "/relative/path")
      refute matches?(links, "")
      refute matches?(links, nil)
    end
  end

  describe "only a live proof counts" do
    test "a link that was never verified marks nothing" do
      never = %Url{value: "https://example.com/", verification_method: nil, verified_at: nil}

      refute matches?([never], "https://example.com/")
    end

    test "a lapsed verification marks nothing" do
      # Vutuv.Profiles.LinkVerification clears both fields when the grace
      # window runs out, so a demoted link looks exactly like a fresh one.
      lapsed = %Url{value: "https://example.com/", verification_method: nil, verified_at: nil}

      refute matches?([lapsed], "https://example.com/")
    end

    test "an empty list marks nothing" do
      refute matches?([], "https://example.com/")
    end
  end

  describe "match/2 answers with the proving link" do
    test "so the caller can name the proven address" do
      proven = link("https://example.com/~alice", "rel_me")
      other = link("https://other.example/", "dns")

      assert VerifiedLinks.match("https://example.com/~alice", [other, proven]) == proven
    end
  end

  describe "of/1" do
    test "keeps only the verified links of a loaded association" do
      verified = link("https://example.com/", "dns")
      plain = %Url{value: "https://unproven.example/", verified_at: nil}

      assert VerifiedLinks.of(%{urls: [verified, plain]}) == [verified]
    end

    test "answers [] when the association was not loaded" do
      assert VerifiedLinks.of(%{urls: %Ecto.Association.NotLoaded{}}) == []
      assert VerifiedLinks.of(nil) == []
    end
  end

  describe "scope/1" do
    test "names what the proof covers" do
      assert VerifiedLinks.scope(link("https://example.com/", "dns")) == "host"
      assert VerifiedLinks.scope(link("https://example.com/deep", "well_known")) == "host"
      assert VerifiedLinks.scope(link("https://example.com/", "rel_me")) == "host"
      assert VerifiedLinks.scope(link("https://example.com/~alice", "rel_me")) == "page"
    end
  end

  describe "address/1 — what the mark names" do
    test "a host claim names the host, a page claim the page" do
      assert VerifiedLinks.address(link("https://www.example.com/", "dns")) == "example.com"

      assert VerifiedLinks.address(link("https://example.com/~alice/", "rel_me")) ==
               "example.com/~alice"
    end
  end
end
