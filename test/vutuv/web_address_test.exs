defmodule Vutuv.WebAddressTest do
  use ExUnit.Case, async: true

  alias Vutuv.WebAddress

  doctest Vutuv.WebAddress

  describe "link_only?/1 says yes to" do
    test "a bare URL, with or without scheme, path or trailing slash" do
      assert WebAddress.link_only?("https://www.sbasf.com/")
      assert WebAddress.link_only?("http://paidviewpoint.com/?r=n6ngcs")
      assert WebAddress.link_only?("www.mrheissam.net")
      assert WebAddress.link_only?("Www.google.com")
      assert WebAddress.link_only?("sbasf.com")
      assert WebAddress.link_only?("onlinecasinoprofy.com/de/casino/")
      assert WebAddress.link_only?("mastodon.social/@someone")
    end

    test "an email address" do
      assert WebAddress.link_only?("norumtiye220@gmail.com")
      assert WebAddress.link_only?("mailto:kontakt@example.de")
    end

    test "several addresses with nothing but punctuation between them" do
      assert WebAddress.link_only?("https://example.com, https://example.org")
    end

    test "an address dressed up as a link, label and all" do
      # The SEO-spam shape seen in production: the same URL as HTML, BBCode and
      # Markdown. A link's label is part of the link, not a self-description.
      assert WebAddress.link_only?(~s(<a href="https://spam.example">Cheap Slots</a>))
      assert WebAddress.link_only?("[url=https://spam.example]Cheap Slots[/url]")
      assert WebAddress.link_only?("[Cheap Slots](https://spam.example)")
    end

    test "surrounding whitespace" do
      assert WebAddress.link_only?("  https://example.com \n")
    end
  end

  describe "link_only?/1 says no to" do
    test "a tagline that merely mentions a site" do
      assert WebAddress.link_only?("Co-Founder of Taxdoo (www.taxdoo.com)") == false
      assert WebAddress.link_only?("Full CV: https://example.github.io/cv.docx") == false
      assert WebAddress.link_only?("Softwareentwickler, Inhaber (www.arcusx.com)") == false
    end

    test "a technology tag whose name merely looks domain-shaped" do
      # These share their spelling with a real TLD, which is why the domain
      # check runs off a curated list instead of the whole registry.
      for name <- ~w(node.js vue.js three.js asp.net vb.net .net socket.io stud.ip
                     xamarin.forms i.s.h.med iq.suite C# TCP/IP CI/CD) do
        refute WebAddress.link_only?(name), "#{name} must stay a valid tag"
      end
    end

    test "ordinary prose, German colon forms included" do
      refute WebAddress.link_only?("Software Consultant")
      refute WebAddress.link_only?("Berater:innen für Digitalisierung")
      refute WebAddress.link_only?("Java")
    end

    test "blank or non-string input" do
      refute WebAddress.link_only?("")
      refute WebAddress.link_only?("   ")
      refute WebAddress.link_only?(nil)
    end

    test "junk that holds no address at all" do
      # Three tags in the production data are "-", "." and "????????". They are
      # worthless, but this rule may not tell their author they typed a URL.
      for junk <- ["-", ".", "????????", "!!!"], do: refute(WebAddress.link_only?(junk))
    end
  end

  describe "link_only?/1 caps its input before the regex battery (F20)" do
    test "a value longer than the varchar(255) column is refused outright" do
      # A single long URL is link-only when it fits the column, but a value too
      # long to ever be a stored headline or tag is short-circuited to false —
      # the guard flips this exact result, so the test fails without it.
      short_url = "https://example.com/cv"
      assert WebAddress.link_only?(short_url) == true

      over_limit = "https://example.com/" <> String.duplicate("a", 2_000)
      assert WebAddress.link_only?(over_limit) == false
    end

    test "a ~1 MB free-text payload returns false fast, not after an O(n²) scan" do
      # The pathological ReDoS input the finding describes: length-unvalidated
      # free text ending in a slash. Without the guard each of the nine
      # unanchored patterns bump-alongs at O(n²) over ~1 MB; with it the byte
      # cap returns instantly. Assert both the result and that it is fast.
      giant = String.duplicate("a", 1_000_000) <> "/"

      {micros, result} = :timer.tc(fn -> WebAddress.link_only?(giant) end)

      assert result == false
      assert micros < 100_000, "expected a fast short-circuit, took #{micros}µs"
    end

    test "a storable multi-byte link-only value is still caught, not clipped by the byte cap" do
      # A value can be ≤255 *characters* (so it fits varchar(255)) yet exceed
      # 255 *bytes* when it uses multi-byte characters. Such a value is still
      # storable, so a link-only one must still be refused — the byte cap sits
      # above any storable value's byte size (255 chars × 4 = 1020) precisely so
      # it is not clipped. A naive 255-*byte* cap would wrongly accept this.
      multibyte_url = "https://" <> String.duplicate("ü", 240) <> ".de"
      assert String.length(multibyte_url) <= 255
      assert byte_size(multibyte_url) > 255
      assert WebAddress.link_only?(multibyte_url) == true
    end
  end
end
