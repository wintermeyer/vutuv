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
end
